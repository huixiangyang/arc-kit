@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import Foundation
import Testing

@Suite("壁纸来源恢复")
struct WallpaperDiscoveryTests {
    @Test("刷新按来源替换，失败保留旧内容，分页与连续刷新不丢结果")
    @MainActor
    func partialRefreshRecovery() async throws {
        let channels = Array(WallpaperChannel.builtins.prefix(2))
        let fixture = DiscoveryRefreshFixture(firstID: channels[0].id)
        let browser = WallpaperMixedBrowser<DiscoveryItem> { try await fixture.fetch($0, query: $1, page: $2) }
        defer { browser.stop() }

        browser.search(channels: channels, query: "")
        try await settle(browser)
        #expect(browser.items.map(\.id) == ["a-old", "b-old"])

        await fixture.setPhase(.partial)
        browser.search(channels: channels, query: "")
        #expect(browser.items.map(\.id) == ["a-old", "b-old"] && browser.showingPrevious)
        try await settle(browser)
        #expect(browser.items.map(\.id) == ["b-old", "a-new"])
        #expect(browser.showingPrevious && browser.failures.keys.sorted() == [channels[1].id])
        let beforeNextPage = browser.items
        browser.loadMore()
        try await settle(browser)
        #expect(Array(browser.items.prefix(beforeNextPage.count)) == beforeNextPage)
        #expect(browser.items.last?.id == "a-next" && !browser.hasMore)
        #expect(await fixture.requests(channel: channels[0].id, page: 2) == 1)
        #expect(await fixture.requests(channel: channels[1].id, page: 2) == 0)

        // 再次刷新全部失败时，上一轮已更新与未更新的来源都必须保留。
        await fixture.setPhase(.failure)
        let beforeFailure = browser.items
        browser.search(channels: channels, query: "")
        try await settle(browser)
        #expect(browser.items == beforeFailure && browser.showingPrevious && browser.failures.count == 2)

        await fixture.setPhase(.emptySecond)
        browser.retry(channels[1].id)
        try await settle(browser)
        #expect(browser.items.map(\.id) == ["a-new", "a-next"])
        #expect(browser.showingPrevious && browser.failures.keys.sorted() == [channels[0].id])

        await fixture.setPhase(.recovered)
        browser.retry(channels[0].id)
        try await settle(browser)
        #expect(browser.items.map(\.id) == ["a-latest"])
        #expect(!browser.showingPrevious && browser.failures.isEmpty)

        browser.search(channels: channels, query: "different")
        #expect(browser.items.isEmpty && !browser.showingPrevious)
        try await settle(browser)
        #expect(browser.items.map(\.id) == ["different-a", "different-b"])
        #expect(browser.query == "different" && browser.failures.isEmpty)
    }

    @Test("来源配置冲突显式重读后可重试开关与订阅，保留另一实例已提交内容")
    @MainActor
    func configurationConflictRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-Discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root))
        defer { try? database.close() }
        let first = WallpaperChannels(database: database, fetchFeed: { _ in ("Fixture feed", []) })
        let second = WallpaperChannels(database: database)
        await first.load(); await second.load()
        try #require(first.loaded && second.loaded)
        let channels = Array(WallpaperChannel.builtins.prefix(2))

        await first.setEnabled(channels[0], false)
        try #require(first.error == nil)
        await second.setEnabled(channels[1], false)
        #expect(second.error != nil && channels.allSatisfy { second.isEnabled($0) })
        await second.load(force: true)
        #expect(second.error == nil && !second.isEnabled(channels[0]) && second.isEnabled(channels[1]))
        await second.setEnabled(channels[1], false)
        try #require(second.error == nil)

        let address = "https://example.org/wallpaper-discovery.json"
        do {
            try await first.subscribe(address)
            Issue.record("旧配置实例添加订阅必须报告冲突")
        } catch {}
        #expect(first.feeds.isEmpty && first.isEnabled(channels[1]))
        await first.load(force: true)
        try #require(first.error == nil)
        try await first.subscribe(address)

        let reloaded = WallpaperChannels(database: database)
        await reloaded.load()
        #expect(reloaded.loaded && reloaded.error == nil)
        #expect(channels.allSatisfy { !reloaded.isEnabled($0) })
        #expect(reloaded.feeds.count == 1 && reloaded.feeds.first?.url.absoluteString == address)
    }

    @MainActor
    private func settle(_ browser: WallpaperMixedBrowser<DiscoveryItem>) async throws {
        for _ in 0..<200 where browser.busy { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!browser.busy)
    }
}

private struct DiscoveryItem: Identifiable, Equatable, Sendable {
    let id: String
}

private actor DiscoveryRefreshFixture {
    enum Phase: Sendable { case initial, partial, failure, emptySecond, recovered }
    private let firstID: String
    private var phase: Phase = .initial
    private var calls: [String: Int] = [:]
    init(firstID: String) { self.firstID = firstID }
    func setPhase(_ phase: Phase) { self.phase = phase }
    func requests(channel: String, page: Int) -> Int { calls["\(channel)|\(page)", default: 0] }

    func fetch(_ channel: WallpaperChannel, query: String, page: Int) throws -> WallpaperChannelPage<DiscoveryItem> {
        calls["\(channel.id)|\(page)", default: 0] += 1
        let first = channel.id == firstID
        let values: [String]
        var more = false
        if !query.isEmpty {
            values = [query + (first ? "-a" : "-b")]
        } else {
            switch phase {
            case .initial: values = [first ? "a-old" : "b-old"]
            case .partial:
                guard first else { throw DiscoveryFailure.unavailable }
                values = [page == 1 ? "a-new" : "a-next"]
                more = page == 1
            case .failure: throw DiscoveryFailure.unavailable
            case .emptySecond:
                guard !first else { throw DiscoveryFailure.unavailable }
                values = []
            case .recovered: values = first ? ["a-latest"] : []
            }
        }
        return WallpaperChannelPage(items: values.map { DiscoveryItem(id: $0) }, more: more)
    }
}

private enum DiscoveryFailure: Error { case unavailable }
