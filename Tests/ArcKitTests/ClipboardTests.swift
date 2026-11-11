@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import AppKit
import CloudKit
import Foundation
import Testing

@Suite("剪贴板本地历史与同步契约")
struct ClipboardTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-Clipboard-\(UUID().uuidString)").resolvingSymlinksInPath() }
    private func item(_ text: String = "项目链接与交付说明") -> ClipboardItem {
        ClipboardItem(content: .init(kind: .text, text: text), sourceBundleID: "test.editor", sourceName: "Editor", deviceName: "Test Mac")
    }

    @Test("记录默认关闭，敏感标记、文件引用、排除应用及自身写回不进入历史")
    @MainActor func privacyAndSettings() throws {
        var settings = ClipboardSettings.defaults
        #expect(!ClipboardCapturePolicy.permits(types: ["public.utf8-plain-text"], source: "test.editor", settings: settings))
        settings.isEnabled = true
        #expect(ClipboardCapturePolicy.permits(types: ["public.utf8-plain-text"], source: "test.editor", settings: settings))
        for marker in ClipboardCapturePolicy.excludedTypes.union(["public.file-url"]) {
            #expect(!ClipboardCapturePolicy.permits(types: [marker, "public.utf8-plain-text"], source: "test.editor", settings: settings))
        }
        #expect(!ClipboardCapturePolicy.permits(types: ["public.utf8-plain-text"], source: "com.apple.Passwords", settings: settings))
        settings.retentionDays = -1
        #expect(throws: (any Error).self) { try settings.validate() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let access = ClipboardSystemAccess(pasteboard: pasteboard)
        let content = ClipboardContent(kind: .text, text: "精确原文", rtf: Data("{\\rtf1 original}".utf8))
        try access.copy(content, plain: false)
        #expect(pasteboard.data(forType: .rtf) == content.rtf)
        #expect(pasteboard.string(forType: .init(ClipboardCapturePolicy.ownType)) == "1")
        try access.copy(content, plain: true)
        #expect(pasteboard.string(forType: .string) == content.text && pasteboard.data(forType: .rtf) == nil)
    }

    @Test("旧数据库补关闭配置，不改变运行代次；完整备份保留历史但撤销云端许可")
    func migrationAndBackup() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let before = try repository.loadSnapshot()
        try repository.database.write { db in
            try db.execute(sql: "DROP TABLE clipboard_items; DROP TABLE clipboard_sync_state; DROP TABLE clipboard_preferences; DELETE FROM grdb_migrations WHERE identifier='clipboard-history-v1'")
        }
        try repository.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        let upgraded = try reopened.loadSnapshot()
        #expect(upgraded.settings == before.settings)
        #expect(upgraded.revision.runtime == before.revision.runtime)
        let store = ClipboardStore(database: reopened.database)
        let entry = item()
        try store.insert(entry, account: nil)
        try store.approve(account: "A")
        var settings = upgraded.settings; settings.clipboard.isEnabled = true; settings.clipboard.syncEnabled = true
        try reopened.save(settings)
        let backup = try StorageMaintenance(database: reopened.database).backup(full: true)
        try store.clearLocal(account: "A")
        try StorageMaintenance(database: reopened.database).restore(backup)
        #expect(try store.item(id: entry.id, account: "A")?.content == entry.content)
        #expect(try !store.state().approved)
        #expect(try !reopened.load().clipboard.syncEnabled)
        #expect(try reopened.load().clipboard.isEnabled)
        try reopened.database.close()
    }

    @Test("搜索收藏、上传范围、账户隔离与本机清理不复活")
    func historyScopeAndAccounts() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = ClipboardStore(database: repository.database)
        let entry = item()
        try store.insert(entry, account: nil)
        try store.insert(item(), account: nil)
        #expect(try store.list(account: nil).count == 1)
        #expect(try store.list(account: nil, search: "交付").count == 1)
        try store.approve(account: "A")
        #expect(try store.pending(account: "A", scope: .favorites).isEmpty)
        try store.setFavorite(id: entry.id, account: "A", value: true)
        let shared = try #require(store.pending(account: "A", scope: .favorites).first?.item)
        try store.merge([.init(item: shared, systemFields: Data([1]))], token: Data([9]), account: "A")
        #expect(try store.pending(account: "A", scope: .favorites).isEmpty)
        try store.clearLocal(account: "A")
        try store.merge([.init(item: shared, systemFields: Data([2]))], token: Data([10]), account: "A")
        #expect(try store.list(account: "A").isEmpty)
        try store.revokeApproval()
        #expect(throws: (any Error).self) { try store.merge([], token: Data([11]), account: "A") }
        try store.approve(account: "B")
        #expect(try store.state().token == nil)
        #expect(try store.list(account: "B").isEmpty)
        #expect(try store.pending(account: "B", scope: .history).isEmpty)
        try repository.database.close()
    }

    @Test("并发修订确定合并，删除优先；错误批次不推进令牌，离线回包不覆盖更新")
    func conflictDeletionAndToken() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = ClipboardStore(database: repository.database)
        try store.approve(account: "A")
        var entry = item(); entry.favorite = true
        try store.insert(entry, account: "A")
        try store.merge([.init(item: entry, systemFields: Data([1]))], token: Data([1]), account: "A")
        try store.setFavorite(id: entry.id, account: "A", value: false)
        // 模拟上传期间发生本地取消收藏，旧成功回执不能把新变更标为已同步。
        try store.merge([.init(item: entry, systemFields: Data([2]))], token: nil, account: "A", advanceToken: false)
        #expect(try store.pending(account: "A", scope: .favorites).count == 1)
        #expect(try store.item(id: entry.id, account: "A")?.favorite == false)
        var invalid = entry; invalid.id = "invalid"
        #expect(throws: (any Error).self) { try store.merge([.init(item: invalid, systemFields: Data())], token: Data([99]), account: "A") }
        #expect(try store.state().token == Data([1]))
        try store.deleteEverywhere(id: entry.id, account: "A")
        var stale = entry; stale.modifiedAt = Date().addingTimeInterval(3600)
        try store.merge([.init(item: stale, systemFields: Data([3]))], token: Data([2]), account: "A")
        #expect(try store.list(account: "A").isEmpty)
        let tombstone = try #require(store.pending(account: "A", scope: .favorites).first)
        #expect(tombstone.item.deleted && tombstone.item.content == nil)
        try store.merge([.init(item: tombstone.item, systemFields: Data([4]))], token: nil, account: "A", advanceToken: false)
        #expect(try store.pending(account: "A", scope: .history).isEmpty)
        try repository.database.close()
    }

    @Test("过期删除保留收藏；存为文件不覆盖同名文件且文本不经格式改写")
    func retentionAndFileOutput() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = ClipboardStore(database: repository.database)
        var expired = item("old"); expired.createdAt = Date().addingTimeInterval(-86400 * 9)
        var favorite = item("pinned"); favorite.createdAt = expired.createdAt; favorite.favorite = true
        try store.insert(expired, account: nil); try store.insert(favorite, account: nil)
        try store.prune(account: nil, days: 7)
        #expect(try store.list(account: nil).map(\.id) == [favorite.id])
        let content = ClipboardContent(kind: .text, text: "# 标题\n保留 100% 原文")
        let now = Date()
        let first = try ClipboardFileWriter.save(content, directory: root, markdown: true, now: now)
        let second = try ClipboardFileWriter.save(content, directory: root, markdown: true, now: now)
        #expect(first != second && first.pathExtension == "md")
        #expect(try String(contentsOf: first, encoding: .utf8) == content.text)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
        try repository.database.close()
    }

    @Test("CloudKit 正文放加密字段，编解码不依赖账户或网络")
    func encryptedRecordDecoding() throws {
        let entry = item("不应出现在普通 CloudKit 字段里的正文")
        let record = CKRecord(recordType: "ArcKitClipboardItem", recordID: .init(recordName: entry.id))
        record.encryptedValues["payload"] = try JSONEncoder().encode(entry) as NSData
        #expect(record["payload"] == nil)
        let decoded = try NativeClipboardCloud.decode(record)
        #expect(decoded.item == entry)
        #expect(!decoded.systemFields.isEmpty)
        record.encryptedValues["payload"] = Data("invalid".utf8) as NSData
        #expect(throws: (any Error).self) { try NativeClipboardCloud.decode(record) }

        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhY4AAAAASUVORK5CYII="))
        let content = ClipboardContent(kind: .image, png: png)
        let path = try ClipboardFileWriter.save(content, directory: root)
        #expect(path.pathExtension == "png")
        #expect(try Data(contentsOf: path) == png)
        var metadata = entry; metadata.content = .init(kind: .image)
        record.encryptedValues["payload"] = try JSONEncoder().encode(metadata) as NSData
        record["image"] = CKAsset(fileURL: path)
        #expect(try NativeClipboardCloud.decode(record).item.content == content)
    }

    @Test("同步先征得许可，只上传收藏；账户切换丢弃迟到回包且不改剪贴板")
    @MainActor func syncLifecycle() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var settings = try repository.load(); settings.clipboard.syncEnabled = true
        try repository.save(settings)
        let settingsModel = SettingsModel(store: repository)
        await settingsModel.waitForPendingChanges()
        let store = ClipboardStore(database: repository.database)
        var favorite = item("shared"); favorite.favorite = true
        try store.insert(favorite, account: nil); try store.insert(item("local"), account: nil)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("fixture sentinel", forType: .string)
        let count = pasteboard.changeCount
        let cloud = ClipboardCloudFixture()
        let model = ClipboardModel(store: store, settingsModel: settingsModel,
            cloud: cloud, system: ClipboardSystemAccess(pasteboard: pasteboard))
        model.start()
        for _ in 0..<200 {
            if model.syncStatus == .approval { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.syncStatus == .approval)
        #expect(await cloud.uploaded.isEmpty)
        await model.synchronize(approve: true)?.value
        #expect(try store.state().approved)
        #expect(await cloud.uploaded == [favorite.id])
        #expect(try store.state().token == Data([1]))

        await cloud.holdNextFetch()
        let running = model.synchronize()
        for _ in 0..<200 {
            if await cloud.isHolding { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cloud.isHolding)
        // A 的网络请求返回前已切到 B，不能把回包写入新账户或确认上传。
        var remote = item("late A result"); remote.favorite = true
        await cloud.switchAccountAndRelease(remote)
        await running?.value
        #expect(model.syncStatus == .approval)
        #expect(try !store.state().approved)
        #expect(try store.item(id: remote.id, account: "A") == nil)
        #expect(try store.state().token == Data([1]))
        #expect(pasteboard.changeCount == count && pasteboard.string(forType: .string) == "fixture sentinel")
        await model.suspend()
        try repository.database.close()
    }
}

private actor ClipboardCloudFixture: ClipboardCloudTransport {
    var current = "A"
    var uploaded: [String] = []
    private var hold = false
    private var continuation: CheckedContinuation<ClipboardCloudPage, Never>?
    var isHolding: Bool { continuation != nil }
    func account() async throws -> String { current }
    func prepare() async throws {}
    func holdNextFetch() { hold = true }
    func fetch(token: Data?) async throws -> ClipboardCloudPage {
        if hold { return await withCheckedContinuation { continuation = $0 } }
        return .init(changes: [], removed: [], token: Data([1]), more: false)
    }
    func save(_ uploads: [ClipboardUpload]) async throws -> ClipboardCloudSaveResult {
        uploaded += uploads.map(\.item.id)
        return .init(changes: uploads.map { .init(item: $0.item, systemFields: Data([1])) }, failure: nil)
    }
    func switchAccountAndRelease(_ remote: ClipboardItem) {
        current = "B"; hold = false
        continuation?.resume(returning: .init(changes: [.init(item: remote, systemFields: Data([2]))], removed: [], token: Data([2]), more: false))
        continuation = nil
    }
}
