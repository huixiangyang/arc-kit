@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import Foundation
import Testing

@Suite("Agent 会话备份", .serialized)
struct AgentSessionTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-Sessions-" + UUID().uuidString).resolvingSymlinksInPath() }

    @Test("配置迁移、JSON 与完整数据包跨根恢复保持会话资产")
    func settingsAndFullBackup() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root.appendingPathComponent("app"))
        var settings = try repository.load()
        #expect(!settings.agentSessions.isEnabled && settings.agentSessions.sources.isEmpty)
        settings.agentSessions.isEnabled = true
        settings.agentSessions.sources = [.init(name: "Test Codex", path: root.appendingPathComponent("codex").path)]
        let before = try repository.loadSnapshot().revision.runtime
        try repository.save(settings)
        #expect(try repository.loadSnapshot().revision.runtime == before)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let store = AgentSessionStore(database: repository.database)
        let payload = try Self.fixture()
        let version = try store.save(payload, capacityBytes: 10_000_000)
        let backup = try StorageMaintenance(database: repository.database).backup(full: true)
        let other = SettingsRepository(directoryURL: root.appendingPathComponent("other")); _ = try other.load()
        try StorageMaintenance(database: other.database).restore(backup)
        let imported = AgentSessionStore(database: other.database)
        #expect(try imported.versions().count == 1)
        #expect(try imported.payload(imported.versions()[0]) == payload)
        #expect(try other.load() == settings)
        // 坏引用必须在替换当前库之前拒绝。
        try repository.database.write { try $0.execute(sql: "UPDATE assets SET path='assets/media/wrong.session' WHERE path=?", arguments: [version.relativePath]) }
        #expect(throws: (any Error).self) { try StorageMaintenance(database: repository.database).backup(full: true) }
        try repository.database.close(); try other.database.close()
    }

    @Test("原始记录边界、分页序号与符号链接均按真实文件检查")
    func captureBoundaries() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Self.fixture()
        let source = AgentSessionSource(id: payload.sourceID, name: "Fixture", path: root.path)
        let path = root.appendingPathComponent(payload.metadata.relativePath)
        var bytes = payload.rollout; bytes.append(Data("{\"type\":".utf8))
        try ArcKitAtomicFile.writeAtomically(bytes, to: path)
        let metadataDB = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try metadataDB.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
        try metadataDB.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,is_pinned INTEGER)")
            try db.execute(sql: "INSERT INTO threads VALUES (?,?,NULL,0)", arguments: [payload.metadata.sessionID, payload.metadata.title])
        }
        try metadataDB.close()
        let scan = try CodexSessionAdapter().scan([source])
        #expect(scan.sourceErrors.isEmpty, "\(scan.sourceErrors)")
        let row = try #require(scan.rows.first)
        let captured = try CodexSessionAdapter().capture(row, source: source)
        #expect(captured.rollout == payload.rollout)
        #expect(captured.incompleteBytes == 8 && !captured.isComplete)
        #expect(try Data(contentsOf: path) == bytes)
        let parsed = try CodexSessionAdapter.parse(payload.rollout)
        #expect(parsed.mode == "paginated")
        let bad = Data(String(decoding: payload.rollout, as: UTF8.self).replacingOccurrences(of: "\"ordinal\":1", with: "\"ordinal\":0").utf8)
        #expect(throws: (any Error).self) { try CodexSessionAdapter.parse(bad) }
        let auth = root.appendingPathComponent("auth.json")
        try ArcKitAtomicFile.writeAtomically(Data("must-not-copy-this-fixture".utf8), to: auth)
        var referenced = payload.rollout
        referenced.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "ordinal": 3, "payload": ["type": "user_message", "message": "Attachment boundary", "local_images": [auth.path]]]))
        referenced.append(10)
        try ArcKitAtomicFile.writeAtomically(referenced, to: path)
        let referenceRow = try #require(CodexSessionAdapter().scan([source]).rows.first)
        let protected = try CodexSessionAdapter().capture(referenceRow, source: source)
        #expect(protected.attachments.isEmpty && protected.missingAttachments == [auth.path])
        #expect(try protected.encoded().range(of: Data("must-not-copy-this-fixture".utf8)) == nil)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/linked.jsonl"), withDestinationURL: path)
        #expect(try !CodexSessionAdapter().scan([source]).sourceErrors.isEmpty)
    }

    @Test("加密往返、错误口令与篡改拒绝，不导出明文正文")
    func encryptedArchive() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try ArcKitStoragePaths.secureDirectory(root)
        let payload = try Self.fixture()
        let file = root.appendingPathComponent("sessions.arckitsessions")
        try AgentSessionArchive.export([payload], password: "fixture-password-2026", to: file)
        #expect(try AgentSessionArchive.load(from: file, password: "fixture-password-2026") == [payload])
        #expect(throws: (any Error).self) { try AgentSessionArchive.load(from: file, password: "incorrect-password") }
        let data = try Data(contentsOf: file)
        #expect(data.range(of: Data("Keep this exact response.".utf8)) == nil)
        var damaged = data; damaged[damaged.count / 2] ^= 0xff
        try damaged.write(to: file)
        #expect(throws: (any Error).self) { try AgentSessionArchive.load(from: file, password: "fixture-password-2026") }
    }

    @Test("失败批量导入不发布半份数据，保留规则不删除最后完整副本")
    func atomicImportAndRetention() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = AgentSessionStore(database: repository.database)
        var first = try Self.fixture(); first.capturedAt = Date(timeIntervalSince1970: 1000)
        let a = try store.save(first, capacityBytes: 10_000_000)
        #expect(try store.save(first, capacityBytes: 10_000_000).id == a.id)
        var incomplete = first; incomplete.capturedAt = Date(); incomplete.incompleteBytes = 8
        let b = try store.save(incomplete, capacityBytes: 10_000_000)
        try store.prune(days: 1)
        #expect(try store.versions().count == 2)
        try store.retain(a, value: true)
        var different = try Self.fixture(id: UUID().uuidString.lowercased())
        different.capturedAt = Date()
        try repository.database.write { try $0.execute(sql: "CREATE TRIGGER fail_session_insert BEFORE INSERT ON agent_session_search_entries BEGIN SELECT RAISE(FAIL,'injected'); END") }
        #expect(throws: (any Error).self) { try store.saveBatch([different, first], capacityBytes: 10_000_000) }
        #expect(try Set(store.versions().map(\.id)) == Set([a.id, b.id]))
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER fail_session_insert") }
        #expect(throws: (any Error).self) { try store.saveBatch([different], capacityBytes: 1) }
        #expect(try store.payload(a) == first)
        try repository.database.close()
    }

    @Test("跨会话正文搜索定位历史版本，支持短中文与字面查询并排除工具内容")
    func savedMessageSearch() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = AgentSessionStore(database: repository.database)
        var original = try Self.fixture()
        let text = "旧版本的会话恢复办法。 Café \"OR\" retry_% remains literal."
        original.rollout = Data(String(decoding: original.rollout, as: UTF8.self).replacingOccurrences(of: "Keep this exact response.", with: text.replacingOccurrences(of: "\"", with: "\\\"")).utf8)
        original.capturedAt = Date().addingTimeInterval(-4 * 86400)
        var tool = try JSONSerialization.data(withJSONObject: ["type": "response_item", "ordinal": 3,
            "payload": ["type": "function_call_output", "output": "AUTH_ONLY_CANARY"]])
        tool.append(10); original.rollout.append(tool)
        let oldVersion = try store.save(original, capacityBytes: 10_000_000)
        var latest = original
        latest.capturedAt = Date()
        latest.metadata.project = "/tmp/Moved-Project"
        latest.rollout = Data(String(decoding: original.rollout, as: UTF8.self).replacingOccurrences(of: "旧版本的会话恢复办法", with: "当前版本已换成新方案").replacingOccurrences(of: "ArcKit-Fixture", with: "Moved-Project").utf8)
        let latestVersion = try store.save(latest, capacityBytes: 10_000_000)
        var other = try Self.fixture(id: UUID().uuidString.lowercased(), title: "会话恢复", project: "/tmp/Other-Project")
        other.sourceID = UUID()
        _ = try store.save(other, capacityBytes: 10_000_000)
        let request = AgentSessionSearchRequest(text: "恢复", sourceID: original.sourceID, project: original.metadata.project)
        let short = try store.search(request)
        #expect(short.hits.count == 1 && short.hits[0].version.id == oldVersion.id)
        #expect(try store.search(.init(text: "恢复", sourceID: original.sourceID, project: latest.metadata.project)).hits.isEmpty)
        let hit = try #require(short.hits.first)
        let entry = try #require(CodexSessionAdapter.transcript(store.payload(hit.version).rollout).first { $0.id == hit.entryID })
        #expect(entry.text.contains("会话恢复办法") && hit.excerpt.contains("会话恢复办法"))
        #expect(try store.search(.init(text: "会话恢复", sourceID: nil, project: "")).hits.count == 2)
        #expect(try store.search(.init(text: "CAFE", sourceID: original.sourceID, project: "")).hits.first?.version.id == latestVersion.id)
        #expect(try store.search(.init(text: "\"OR\"", sourceID: original.sourceID, project: "")).hits.count == 1)
        #expect(try store.search(.init(text: "retry_%", sourceID: nil, project: "")).hits.count == 1)
        #expect(try store.search(.init(text: "\" OR \"missing", sourceID: nil, project: "")).hits.isEmpty)
        #expect(try store.search(.init(text: "AUTH_ONLY_CANARY", sourceID: nil, project: "")).hits.isEmpty)
        #expect(try store.search(.init(text: "恢复", sourceID: original.sourceID, project: other.metadata.project)).hits.isEmpty)
        #expect(try store.search(.init(text: "恢复", sourceID: nil, project: ""), limit: 1).hasMore)
        try store.prune(days: 1)
        #expect(try store.search(request).hits.isEmpty)
        try repository.database.close()
    }

    @Test("旧备份懒建搜索索引，检查点复用正文且轮换删除索引")
    func searchIndexBackfill() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root); _ = try repository.load()
        let store = AgentSessionStore(database: repository.database)
        var payload = try Self.fixture()
        let first = try store.save(payload, capacityBytes: 10_000_000)
        payload.capturedAt = Date().addingTimeInterval(1)
        let checkpoint = try store.save(payload, capacityBytes: 10_000_000, forceCheckpoint: true)
        #expect(first.id != checkpoint.id && first.relativePath == checkpoint.relativePath)
        #expect(try repository.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM agent_session_search_documents") } == 1)
        // 模拟旧完整备份迁移后的空派生表；正文仅从已保存资产补回。
        try repository.database.write { try $0.execute(sql: "DELETE FROM agent_session_search_documents") }
        let request = AgentSessionSearchRequest(text: "exact response", sourceID: nil, project: "")
        #expect(try store.search(request).hits.isEmpty)
        try store.prepareSearchIndex()
        #expect(try store.search(request).hits.first?.version.id == checkpoint.id)
        #expect(try repository.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM agent_session_search_documents") } == 1)
        try repository.database.close()
    }

    @Test("恢复计划区分相同与冲突，拒绝路径越界")
    func restorePlan() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Self.fixture()
        let target = root.appendingPathComponent("codex")
        let service = CodexSessionRestore(temporaryRoot: root.appendingPathComponent("tmp"))
        #expect(try service.plan([payload], destination: target).items[0].disposition == .new)
        try ArcKitAtomicFile.writeAtomically(payload.rollout, to: target.appendingPathComponent(payload.metadata.relativePath))
        #expect(try service.plan([payload], destination: target).items[0].disposition == .identical)
        var changed = payload; changed.rollout = Data(String(decoding: payload.rollout, as: UTF8.self).replacingOccurrences(of: "Keep this exact response.", with: "Different response.").utf8)
        #expect(try service.plan([changed], destination: target).items[0].disposition == .conflict)
        changed.metadata.relativePath = "sessions/../../auth.json"
        #expect(throws: (any Error).self) { try changed.validated() }
    }

    @Test("自动保护、源删除与恢复互斥保持真实状态")
    @MainActor func modelLifecycle() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Self.fixture()
        let source = root.appendingPathComponent("codex")
        let file = source.appendingPathComponent(payload.metadata.relativePath)
        try ArcKitAtomicFile.writeAtomically(payload.rollout, to: file)
        let repository = SettingsRepository(directoryURL: root.appendingPathComponent("app"))
        var config = try repository.load(); config.agentSessions.isEnabled = true
        config.agentSessions.sources = [.init(id: payload.sourceID, name: "Fixture", path: source.path)]
        try repository.save(config)
        let settings = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: repository.database.paths.templates))
        await settings.waitForPendingChanges()
        let model = AgentSessionModel(settings: settings, isPreview: true)
        model.start(); await model.waitUntilIdle()
        #expect(model.failure == nil)
        #expect(model.versions.count == 1 && model.rows.count == 1)
        let saved = try #require(model.versions.first)
        try FileManager.default.removeItem(at: file)
        model.refresh(); await model.waitUntilIdle()
        #expect(model.rows.first?.sourceMissing == true)
        #expect(try model.store.payload(saved).rollout == payload.rollout)
        let oldPage = UUID(), currentPage = UUID()
        model.searchBackups(.init(text: "missing phrase", sourceID: nil, project: ""), owner: oldPage)
        model.searchBackups(.init(text: "exact response", sourceID: nil, project: ""), owner: currentPage)
        model.endSearch(owner: oldPage)
        await model.waitUntilSearchFinishes()
        #expect(model.searchFailure == nil && model.searchResult.hits.first?.version.id == saved.id)
        model.searchBackups(.init(text: "another pending query", sourceID: nil, project: ""))
        await model.suspendAndWait()
        #expect(!model.isSearching && model.searchResult.hits.isEmpty)
        model.refresh(backup: true)
        #expect(!model.isWorking)
        try repository.database.close()
    }

    @Test("中断恢复回退已有文件且拒绝越界日志")
    func interruptedRecovery() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transaction = root.appendingPathComponent(".arc-kit-recovery/" + UUID().uuidString)
        let relative = "sessions/2026/10/23/rollout-test.jsonl"
        try ArcKitAtomicFile.writeAtomically(Data("old".utf8), to: transaction.appendingPathComponent("original/" + relative))
        try ArcKitAtomicFile.writeAtomically(Data("new".utf8), to: root.appendingPathComponent(relative))
        let journal: [String: Any] = ["phase": "applying", "applied": 1, "entries": [["path": relative, "existed": true, "publish": true]]]
        try ArcKitAtomicFile.writeAtomically(PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0), to: transaction.appendingPathComponent("journal.plist"))
        #expect(try CodexSessionRestore.pendingRecovery(at: root)?.path == transaction.path)
        try CodexSessionRestore.rollback(transaction, destination: root)
        #expect(try Data(contentsOf: root.appendingPathComponent(relative)) == Data("old".utf8))
        #expect(try CodexSessionRestore.pendingRecovery(at: root) == nil)
        let bad: [String: Any] = ["phase": "applying", "applied": 1, "entries": [["path": "auth.json", "existed": false, "publish": true]]]
        try ArcKitAtomicFile.writeAtomically(PropertyListSerialization.data(fromPropertyList: bad, format: .binary, options: 0), to: transaction.appendingPathComponent("journal.plist"))
        #expect(throws: (any Error).self) { try CodexSessionRestore.rollback(transaction, destination: root) }
    }

    static func fixture(id: String = "018f2100-0000-7000-8000-000000000001", title: String = "Recovery fixture", project: String = "/tmp/ArcKit-Fixture") throws -> AgentSessionPayload {
        let sourceID = UUID(uuidString: "018f2100-0000-7000-8000-000000000000")!
        let meta: [String: Any] = ["id": id, "timestamp": "2026-10-23T00:00:00Z", "cwd": project, "cli_version": "0.163.0", "history_mode": "paginated", "model_provider": "openai", "source": "cli", "originator": "arc-kit-tests"]
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": meta],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": title]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Keep this exact response."]]]]
        ]
        var data = Data()
        for (ordinal, record) in records.enumerated() { var record = record; record["ordinal"] = ordinal; record["timestamp"] = "2026-10-23T00:00:00Z"; data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10) }
        let date = Date(timeIntervalSince1970: 1792713600)
        return .init(sourceID: sourceID, sourceName: "Fixture Codex", capturedAt: Date(), metadata: .init(sessionID: id, title: title, project: project,
            createdAt: date, modifiedAt: date, cliVersion: "0.163.0", historyMode: "paginated", archived: false, childIDs: [], pinned: false,
            relativePath: "sessions/2026/10/23/rollout-2026-10-23T00-00-00-\(id).jsonl", modelProvider: "openai"), rollout: data, attachments: [], missingAttachments: [], incompleteBytes: 0, changedDuringRead: false)
    }
}
