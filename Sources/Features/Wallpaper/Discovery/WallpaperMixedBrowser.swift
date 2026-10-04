import ArcKitPlatform
import Combine
import Foundation

struct WallpaperChannelPage<Item: Sendable>: Sendable {
    let items: [Item]
    let more: Bool
}

/// 浏览会话由 WallpaperModel 持有；分页按批次混排，切换标签不重新下载目录。
@MainActor
final class WallpaperMixedBrowser<Item: Identifiable & Sendable>: ObservableObject where Item.ID: Sendable {
    typealias Fetch = @Sendable (WallpaperChannel, String, Int) async throws -> WallpaperChannelPage<Item>
    private struct Batch {
        let id: UUID
        let order: [String]
        var items: [String: [Item]] = [:]
    }
    @Published var searchText = ""
    @Published private(set) var query = ""
    @Published private(set) var channels: [WallpaperChannel] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var more: Set<String> = []
    @Published private(set) var paused: Set<String> = []
    @Published private(set) var showingPrevious = false
    private var started = false
    private var pages: [String: Int] = [:]
    private var batches: [Batch] = []
    private var previousBatches: [Batch] = []
    private let fetch: Fetch
    private var work: Task<Void, Never>?
    private var generation = UUID()
    var busy: Bool { !loading.isEmpty }
    var hasMore: Bool { !more.subtracting(Set(failures.keys)).isEmpty || !paused.isEmpty }

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    func activate(channels: [WallpaperChannel]) {
        guard started else { search(channels: channels, query: searchText); return }
        guard channels != self.channels else { return }
        stop()
        let oldIDs = Set(self.channels.map(\.id)), enabled = Set(channels.map(\.id))
        self.channels = channels
        pages = pages.filter { enabled.contains($0.key) }
        failures = failures.filter { enabled.contains($0.key) }
        more.formIntersection(enabled); paused.formIntersection(enabled)
        for i in batches.indices { batches[i].items = batches[i].items.filter { enabled.contains($0.key) } }
        for i in previousBatches.indices { previousBatches[i].items = previousBatches[i].items.filter { enabled.contains($0.key) } }
        publishItems()
        // 开关只影响变化的渠道；已成功渠道保留结果与页码，不重复请求。
        request(channels.filter { !oldIDs.contains($0.id) || paused.contains($0.id) })
    }
    func search(channels: [WallpaperChannel], query: String) {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        let keep = started && term == self.query && channels == self.channels && !items.isEmpty
        // 连续刷新时，新旧结果可能并存；两部分都保留来源归属，直到各自刷新成功。
        previousBatches = keep ? previousBatches + batches : []
        previousBatches.removeAll { $0.items.values.allSatisfy(\.isEmpty) }
        stop(); started = true
        self.channels = channels; self.query = term; searchText = term
        showingPrevious = keep
        if !keep { items = [] }
        failures = [:]; more = []; paused = []; pages = [:]; batches = []
        request(channels)
    }
    func loadMore() {
        guard !busy else { return }
        request(channels.filter { paused.contains($0.id) || more.contains($0.id) && failures[$0.id] == nil })
    }
    func retry(_ id: String) {
        guard !busy, failures[id] != nil else { return }
        request(channels.filter { $0.id == id })
    }
    func retryFailures() {
        guard !busy else { return }
        request(channels.filter { failures[$0.id] != nil })
    }
    func stop() {
        work?.cancel(); work = nil; generation = UUID()
        paused.formUnion(loading); loading = []
    }
    private func request(_ requested: [WallpaperChannel]) {
        guard !requested.isEmpty else { return }
        let token = UUID(); generation = token
        let fetch = fetch, query = query
        let requests = requested.map { ($0, (pages[$0.id] ?? 0) + 1) }
        batches.removeAll { $0.items.isEmpty }
        batches.append(Batch(id: token, order: requested.map(\.id)))
        loading = Set(requested.map(\.id)); paused.subtract(loading)
        for channel in requested { failures.removeValue(forKey: channel.id) }
        work = Task { [weak self] in
            await withTaskGroup(of: (String, Int, Result<WallpaperChannelPage<Item>, Error>).self) { group in
                func enqueue(_ request: (WallpaperChannel, Int)) {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            return (request.0.id, request.1, .success(try await fetch(request.0, query, request.1)))
                        } catch { return (request.0.id, request.1, .failure(error)) }
                    }
                }
                var queued = 0
                while queued < min(4, requests.count) { enqueue(requests[queued]); queued += 1 }
                for await (id, page, result) in group {
                    guard let self, self.generation == token, !Task.isCancelled else { group.cancelAll(); return }
                    self.loading.remove(id)
                    switch result {
                    case .success(let result):
                        // 首屏成功才替换该来源的旧页；空结果同样有效，不能继续展示过期内容。
                        if page == 1 {
                            for index in self.previousBatches.indices { self.previousBatches[index].items.removeValue(forKey: id) }
                        }
                        self.pages[id] = page
                        if result.more { self.more.insert(id) } else { self.more.remove(id) }
                        if let index = self.batches.firstIndex(where: { $0.id == token }) { self.batches[index].items[id] = result.items }
                        self.publishItems()
                    case .failure(let error): self.failures[id] = error.localizedDescription
                    }
                    if queued < requests.count { enqueue(requests[queued]); queued += 1 }
                }
            }
        }
    }
    private func publishItems() {
        previousBatches.removeAll { $0.items.values.allSatisfy(\.isEmpty) }
        // 尚未更新的来源保持在前，后续分页始终追加，避免“加载更多”挤动仍可浏览的旧项。
        items = mergedItems(previousBatches + batches)
        showingPrevious = !previousBatches.isEmpty
    }
    private func mergedItems(_ batches: [Batch]) -> [Item] {
        var seen = Set<Item.ID>(), result: [Item] = []
        for batch in batches {
            let rows = batch.order.map { batch.items[$0] ?? [] }
            for index in 0..<(rows.map(\.count).max() ?? 0) {
                for row in rows where index < row.count && seen.insert(row[index].id).inserted { result.append(row[index]) }
            }
        }
        return result
    }
}

extension WallpaperMixedBrowser where Item == OnlineWallpaper {
    static func images() -> WallpaperMixedBrowser {
        WallpaperMixedBrowser { channel, query, page in
            guard case .image(let provider) = channel.source else { throw WallpaperError.message(L10n.string(.WallpaperSources.galleryImageSourceUnavailable)) }
            let result = try await WallpaperOnlineSource.search(provider: provider, query: query, page: page)
            let items = provider.supportsSearch || query.isEmpty ? result.items : result.items.filter {
                ($0.title + " " + ($0.origin.author ?? "")).localizedCaseInsensitiveContains(query)
            }
            return WallpaperChannelPage(items: items, more: result.hasNextPage)
        }
    }
}

extension WallpaperMixedBrowser where Item == MotionWallpaper {
    static func videos() -> WallpaperMixedBrowser {
        WallpaperMixedBrowser { channel, query, page in
            let items: [MotionWallpaper]
            switch channel.source {
            case .nasa:
                let result = try await MotionWallpaperSource.nasa(query: query, page: page)
                return WallpaperChannelPage(items: result.items, more: result.more)
            case .motion: items = try await MotionWallpaperSource.motion(category: "")
            case .feed(let feed): items = try await MotionWallpaperSource.feed(feed.url).items
            case .image: throw WallpaperError.message(L10n.string(.WallpaperSources.galleryVideoSourceUnavailable))
            }
            return WallpaperChannelPage(items: query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }, more: false)
        }
    }
}
