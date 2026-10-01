import ArcKitPlatform
import ArcKitPersistence
import Combine
import Foundation

enum WallpaperChannelKind: String, CaseIterable {
    case image, video
    var title: String { switch self { case .image: L10n.string(.AppBackground.backgroundStorageImage); case .video: L10n.string(.AppBackground.backgroundStorageVideo) } }
}

struct WallpaperChannel: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case image(WallpaperProvider), motion, nasa, feed(WallpaperFeed)
    }
    let source: Source
    var id: String {
        switch source {
        case .image(let provider): "image:\(provider.rawValue)"
        case .motion: "motion"
        case .nasa: "nasa"
        case .feed(let feed): feed.id
        }
    }
    var name: String {
        switch source {
        case .image(let provider): provider.title
        case .motion: "MotionBGS"
        case .nasa: "NASA"
        case .feed(let feed): feed.name
        }
    }
    var kind: WallpaperChannelKind { if case .image = source { .image } else { .video } }
    var detail: String {
        switch source {
        case .image(.wallhaven): L10n.string(.WallpaperSources.sourceSfwWallpapersOnlineSearch)
        case .image(.commons): L10n.string(.WallpaperSources.sourceOpenImagesOnlineSearchAttributionLicenses)
        case .image(.bing): L10n.string(.WallpaperSources.sourceBingDescription)
        case .image(.picsum): L10n.string(.WallpaperSources.sourcePhotographyPicksFilterAuthor)
        case .motion: L10n.string(.WallpaperSources.sourceLiveWallpaperPicksFilterCatalogTitles)
        case .nasa: L10n.string(.WallpaperSources.sourceSpaceNatureVideosOnlineSearchEnglish)
        case .feed(let feed): feed.url.absoluteString
        }
    }
    static var builtins: [Self] {
        WallpaperProvider.allCases.map { Self(source: .image($0)) } + [Self(source: .motion), Self(source: .nasa)]
    }
}

struct WallpaperSourceConfiguration: Codable, Sendable {
    var feeds: [WallpaperFeed] = []
    var disabled: Set<String> = []
    static let recordLayout = ArcKitRecordLayout("wallpaper_source_preferences", fields: ["disabled"], json: ["disabled"], children: [
        "feeds": ArcKitRecordLayout("wallpaper_sources", fields: ["name", "url"])
    ])
}

/// 订阅列表和渠道开关一次事务提交，添加失败不会留下半份新配置。
actor WallpaperChannelStore {
    let database: ArcKitDatabase
    private var generation: Int64?
    init(database: ArcKitDatabase) { self.database = database }
    func load() throws -> WallpaperSourceConfiguration {
        try database.read { db in
            guard let value = try ArcKitRecord.load(WallpaperSourceConfiguration.self, layout: WallpaperSourceConfiguration.recordLayout, db: db) else { throw WallpaperError.message(L10n.string(.WallpaperSources.sourceSourceConfigurationRecordMissing)) }
            generation = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='sources'") ?? 0
            return value
        }
    }
    func save(_ value: WallpaperSourceConfiguration) throws {
        guard value.feeds.count <= 50, Set(value.feeds.map(\.id)).count == value.feeds.count,
              value.feeds.allSatisfy({ WallpaperRemoteAccess.valid($0.url) && !$0.name.isEmpty && $0.name.count <= 100 }),
              value.disabled.count <= 56, value.disabled.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else {
            throw WallpaperError.message(L10n.string(.WallpaperSources.sourceInvalidFeedSourceConfiguration))
        }
        if generation == nil { _ = try load() }
        let next = try database.write { db in
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='sources'") ?? 0
            guard generation == revision else { throw WallpaperError.message(L10n.string(.WallpaperSources.sourceSourceConfigurationChangedReloadSaving)) }
            try ArcKitRecord.save(value, layout: WallpaperSourceConfiguration.recordLayout, db: db)
            try ArcKitDatabase.advance(db)
            try db.execute(sql: "INSERT INTO domain_revisions VALUES('sources',?) ON CONFLICT(domain) DO UPDATE SET revision=excluded.revision", arguments: [revision + 1])
            return revision + 1
        }
        generation = next
    }
}

@MainActor
final class WallpaperChannels: ObservableObject {
    @Published private(set) var feeds: [WallpaperFeed] = []
    @Published private(set) var disabled: Set<String> = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let store: WallpaperChannelStore
    private let fetchFeed: @Sendable (URL) async throws -> (name: String, items: [MotionWallpaper])

    init(database: ArcKitDatabase, fetchFeed: @escaping @Sendable (URL) async throws -> (name: String, items: [MotionWallpaper]) = MotionWallpaperSource.feed) {
        store = WallpaperChannelStore(database: database)
        self.fetchFeed = fetchFeed
    }

    var all: [WallpaperChannel] { WallpaperChannel.builtins + feeds.map { WallpaperChannel(source: .feed($0)) } }
    func isEnabled(_ channel: WallpaperChannel) -> Bool { !disabled.contains(channel.id) }
    func enabled(_ kind: WallpaperChannelKind) -> [WallpaperChannel] {
        loaded ? all.filter { $0.kind == kind && isEnabled($0) } : []
    }
    func load(force: Bool = false) async {
        guard (!loaded || force), !busy else { return }
        busy = true; defer { busy = false }
        do {
            let saved = try await store.load()
            feeds = saved.feeds
            disabled = saved.disabled.intersection(Set(all.map(\.id)))
            error = nil; loaded = true
        } catch { self.error = L10n.string(.WallpaperSources.sourceReadFailed(String(describing: error.localizedDescription))) }
    }
    func setEnabled(_ channel: WallpaperChannel, _ enabled: Bool) async {
        guard loaded, !busy, all.contains(channel) else { return }
        busy = true; defer { busy = false }
        var next = disabled.intersection(Set(all.map(\.id)))
        if enabled { next.remove(channel.id) } else { next.insert(channel.id) }
        do { try await store.save(WallpaperSourceConfiguration(feeds: feeds, disabled: next)); disabled = next; error = nil }
        catch { self.error = L10n.string(.WallpaperSources.sourceSaveFailed(String(describing: error.localizedDescription))) }
    }
    func subscribe(_ text: String) async throws {
        guard loaded, !busy else { throw WallpaperError.message(L10n.string(.WallpaperSources.sourceWaitSourceConfigurationFinishLoading)) }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), WallpaperRemoteAccess.valid(url) else {
            throw WallpaperError.message(L10n.string(.WallpaperSources.sourceEnterCompleteHttpsJsonCatalogUrl))
        }
        guard !feeds.contains(where: { $0.url == url }) else { throw WallpaperError.message(L10n.string(.WallpaperSources.sourceFeedAlreadyAddedEnable)) }
        guard feeds.count < 50 else { throw WallpaperError.message(L10n.string(.WallpaperSources.sourceSubscriptionLimit)) }
        busy = true; defer { busy = false }
        let result = try await fetchFeed(url)
        try Task.checkCancellation()
        let next = feeds + [WallpaperFeed(name: result.name, url: url)]
        // 先清理已移除订阅的开关，不改变任何现有渠道；同址重新添加也默认启用。
        let retained = disabled.intersection(Set(all.map(\.id)))
        try await store.save(WallpaperSourceConfiguration(feeds: next, disabled: retained))
        disabled = retained
        feeds = next; error = nil
    }
    func remove(_ feed: WallpaperFeed) async {
        guard loaded, !busy else { return }
        busy = true; defer { busy = false }
        let next = feeds.filter { $0.id != feed.id }
        do { try await store.save(WallpaperSourceConfiguration(feeds: next, disabled: disabled.subtracting([feed.id]))); feeds = next; disabled.remove(feed.id); error = nil }
        catch { self.error = L10n.string(.WallpaperSources.sourceUnavailableRemoveFeed(String(describing: error.localizedDescription))) }
    }
}
