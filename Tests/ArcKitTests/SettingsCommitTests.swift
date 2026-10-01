import ArcKitPlatform
import ArcKitMouse
@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitFinder
import ArcKitWindow
import Foundation
import Testing

@Suite("设置提交与通信顺序")
struct SettingsCommitTests {
    @Test("UU 默认规则一次性迁移，保留自定义，删除后重启与恢复不补回", arguments: [false, true])
    func uuRemoteDefaultMigrationAndPersistence(existingRule: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var original = try repository.load()
        let bundled = try #require(original.mouseEnhancement.appProfiles.first { $0.bundleIdentifier == "com.netease.uuremote" })
        #expect(original.mouseEnhancement.effectiveTuning(for: bundled.bundleIdentifier) == nil)
        #expect(original.mouseEnhancement.effectiveTuning(for: "com.google.Chrome") != nil)
        original.mouseEnhancement.globalTuning.speedGain = 1.5
        original.mouseEnhancement.scrollScope = .selectedApplications
        original.mouseEnhancement.appProfiles = [MouseAppScrollProfile(displayName: "Chrome", bundleIdentifier: "com.google.Chrome")]
        if existingRule {
            var custom = MouseAppScrollProfile(displayName: "My UU", bundleIdentifier: bundled.bundleIdentifier, behavior: .custom)
            custom.tuning.reverseVertical = false
            custom.tuning.smoothEnabled = false
            original.mouseEnhancement.appProfiles.append(custom)
        }
        let before = try repository.save(original)
        // 模拟尚未交付默认规则的旧安装，迁移不能覆盖用户已有选择或改变作用范围。
        try repository.database.write { db in
            try db.execute(sql: "ALTER TABLE mouse_application_rules DROP COLUMN note")
            try db.execute(sql: "UPDATE mouse_application_rules SET _types=json_remove(_types, '$.note')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('mouse-uu-remote-rule-v1', 'mouse-rule-note-v1')")
        }
        try repository.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        var expected = original
        if !existingRule { expected.mouseEnhancement.appProfiles.append(bundled) }
        #expect(migrated.settings == expected)
        #expect(migrated.revision.runtime == before.revision.runtime + (existingRule ? 0 : 1))
        let host = ArcKitDatabase(reading: upgraded.database.paths)
        #expect(try host.read { db in
            try ArcKitRecord.load(MouseEnhancementSettings.self, layout: MouseEnhancementSettings.recordLayout, db: db) == expected.mouseEnhancement
        })
        try host.close()

        let rule = try #require(expected.mouseEnhancement.appProfiles.first { $0.bundleIdentifier == bundled.bundleIdentifier })
        expected.mouseEnhancement.removeAppProfile(id: rule.id)
        try upgraded.save(expected)
        let storage = StorageMaintenance(database: upgraded.database)
        let deletedBackup = try storage.backup(full: true)
        // JSON 导入同样只采用用户的规则列表，解码不能偷偷补入预置项。
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(expected)) == expected)
        try upgraded.database.close()
        let restarted = SettingsRepository(directoryURL: root)
        #expect(try restarted.load() == expected)
        var edited = expected
        var inherited = bundled
        inherited.behavior = .inherit
        try edited.mouseEnhancement.addAppProfile(inherited)
        try restarted.save(edited)
        #expect(try restarted.load().mouseEnhancement.effectiveTuning(for: bundled.bundleIdentifier) == edited.mouseEnhancement.globalTuning)
        try StorageMaintenance(database: restarted.database).restore(deletedBackup)
        #expect(try restarted.load() == expected)
        try restarted.database.close()
        let restored = SettingsRepository(directoryURL: root)
        #expect(try restored.load() == expected)
        try restored.database.close()
    }

    @Test("应用规则说明迁移、保存和清空不影响滚动，重启与备份保留文字", arguments: [MouseAppScrollBehavior.system, .custom])
    func mouseRuleNoteMigrationAndPersistence(behavior: MouseAppScrollBehavior) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var original = try repository.load()
        #expect(!original.mouseEnhancement.appProfiles[0].note.isEmpty)
        original.mouseEnhancement.appProfiles[0].behavior = behavior
        original.mouseEnhancement.appProfiles.append(.init(displayName: "Safari", bundleIdentifier: "com.apple.Safari"))
        let before = try repository.save(original)
        // build 51 的规则尚无说明列；更早的迁移链由 UU 规则回归覆盖。
        try repository.database.write { db in
            try db.execute(sql: "ALTER TABLE mouse_application_rules DROP COLUMN note")
            try db.execute(sql: "UPDATE mouse_application_rules SET _types=json_remove(_types, '$.note')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='mouse-rule-note-v1'")
        }
        try repository.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        if behavior != .system { original.mouseEnhancement.appProfiles[0].note = "" }
        #expect(migrated.settings == original)
        #expect(migrated.revision.runtime == before.revision.runtime)
        #expect(migrated.revision.data > before.revision.data)

        var edited = migrated.settings
        edited.mouseEnhancement.appProfiles[0].note = "保留 UU's 滚动\nRemote scrolling"
        edited.mouseEnhancement.appProfiles[1].note = "浏览器使用默认参数"
        let committed = try upgraded.save(edited)
        #expect(committed.revision.data > migrated.revision.data)
        #expect(committed.revision.runtime == migrated.revision.runtime)
        #expect(edited.mouseEnhancement.hasSameRuntimeConfiguration(as: original.mouseEnhancement))
        for bundle in ["com.netease.uuremote", "com.apple.Safari", "unlisted.app"] {
            #expect(edited.mouseEnhancement.effectiveTuning(for: bundle) == original.mouseEnhancement.effectiveTuning(for: bundle))
        }
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(edited)) == edited)
        #expect(try upgraded.load() == edited)

        let storage = StorageMaintenance(database: upgraded.database)
        let editedBackup = try storage.backup(full: true)
        var cleared = edited
        cleared.mouseEnhancement.appProfiles[0].note = ""
        #expect(try upgraded.save(cleared).revision.runtime == committed.revision.runtime)
        let clearedBackup = try storage.backup(full: true)
        try upgraded.database.close()
        let restarted = SettingsRepository(directoryURL: root)
        #expect(try restarted.load() == cleared)
        let restoredStorage = StorageMaintenance(database: restarted.database)
        try restoredStorage.restore(editedBackup)
        #expect(try restarted.load() == edited)
        try restoredStorage.restore(clearedBackup)
        #expect(try restarted.load() == cleared)
        try restarted.database.close()
    }

    @Test("菜单栏显示迁移保留旧配置，隐藏选择可保存、恢复且不改变后台代次")
    func menuBarVisibilityMigrationAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var original = try repository.load()
        original.showDockIcon = false
        original.appearance = .dark
        original.finder.defaultTerminal = .iTerm
        let before = try repository.save(original)
        // 模拟已安装版本的数据库，升级只补菜单栏选择，不恢复其他偏好默认值。
        try repository.database.write { db in
            try db.execute(sql: "ALTER TABLE app_preferences DROP COLUMN showMenuBarIcon")
            try db.execute(sql: "UPDATE app_preferences SET _types=json_remove(_types, '$.showMenuBarIcon')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='menu-bar-visibility-v1'")
        }
        try repository.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        let migrated = try reopened.loadSnapshot()
        #expect(migrated.settings == original)
        #expect(migrated.revision.runtime == before.revision.runtime)
        var hidden = migrated.settings
        hidden.showMenuBarIcon = false
        let saved = try reopened.save(hidden)
        #expect(saved.revision.data > migrated.revision.data)
        #expect(saved.revision.runtime == migrated.revision.runtime)
        #expect(try reopened.load() == hidden)
        let storage = StorageMaintenance(database: reopened.database)
        let backup = try storage.backup(full: true)
        try reopened.save(original)
        try storage.restore(backup)
        #expect(try reopened.load() == hidden)
        try reopened.database.close()
        let restarted = SettingsRepository(directoryURL: root)
        #expect(try restarted.load() == hidden)
        try restarted.database.close()
    }

    @Test("Finder 菜单选择可保存，修复 build 45 缺失值且保留已有关闭状态")
    func finderMenuSelectionPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var original = try repository.load()
        original.finder.menuConfiguration.favoriteDirectories = [FavoriteDirectory(name: "工作", path: root.path)]
        original.finder.menuConfiguration.moveModuleInDisplayOrder(from: 0, offset: 3)
        try repository.save(original)
        // 模拟 build 45 写出的缺失字段，再由下一次主应用启动执行一次性修复。
        try repository.database.write { db in
            try db.execute(sql: "UPDATE finder_modules SET enabled=NULL, _types=json_remove(_types, '$.enabled') WHERE moduleID IN ('newFile', 'favoriteApps')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='finder-menu-selection-v1'")
        }
        try repository.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        var loaded = try reopened.load()
        #expect(loaded == original, "缺失的新建和应用恢复选中，目录已有的关闭值不能被覆盖")
        for index in loaded.finder.menuConfiguration.modules.indices {
            loaded.finder.menuConfiguration.modules[index].isEnabled.toggle()
        }
        try reopened.save(loaded)
        #expect(try reopened.load() == loaded)
        #expect(try reopened.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM finder_modules WHERE enabled IS NULL") == 0
        })
        let host = ArcKitDatabase(reading: reopened.database.paths)
        #expect(try host.read { db in
            try ArcKitRecord.load(FinderRuntimeSettings.self, layout: FinderRuntimeSettings.recordLayout, db: db) == loaded.finder
        })
        try host.close()
        try reopened.database.close()
        #expect(try SettingsRepository(directoryURL: root).load() == loaded, "重新启动不能重新勾选用户关闭的功能")
    }

    @Test("SQL 中断整批回滚，Host 一次读取已提交代次")
    func transactionAndReadOnlySnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let original = try repository.loadSnapshot()
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_mouse BEFORE INSERT ON mouse_preferences BEGIN SELECT RAISE(FAIL, 'injected write failure'); END")
        }
        var candidate = original.settings
        candidate.showDockIcon.toggle(); candidate.showMenuBarIcon.toggle(); candidate.mouseEnhancement.isEnabled.toggle()
        #expect(throws: (any Error).self) { try repository.save(candidate) }
        #expect(try repository.loadSnapshot() == original)
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER reject_mouse") }
        let committed = try repository.save(candidate)
        let host = ArcKitDatabase(reading: repository.database.paths)
        let runtime = try host.read { db in
            (try ArcKitRecord.load(MouseEnhancementSettings.self, layout: MouseEnhancementSettings.recordLayout, db: db), try ArcKitDatabase.revision(db))
        }
        #expect(runtime.0 == candidate.mouseEnhancement)
        #expect(runtime.1 == committed.revision)
        #expect(committed.revision.runtime == original.revision.runtime + 1)
        candidate.appearance = .dark
        #expect(try repository.save(candidate).revision.runtime == committed.revision.runtime)
        #expect(throws: (any Error).self) { try host.write { try $0.execute(sql: "DELETE FROM mouse_preferences") } }
        // 使用真实 SQLite 页数上限触发 SQLITE_FULL，验证提交失败而非只模拟业务异常。
        let beforeFull = try repository.loadSnapshot()
        try repository.database.write { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count")!
            try db.execute(sql: "PRAGMA max_page_count=\(pages)")
        }
        do {
            try repository.database.write { db in
                try db.execute(sql: "CREATE TABLE disk_full_fixture(payload BLOB)")
                try db.execute(sql: "INSERT INTO disk_full_fixture VALUES(zeroblob(8388608))")
            }
            Issue.record("必须触发磁盘页数限制")
        } catch let error as DatabaseError { #expect(error.resultCode == .SQLITE_FULL) }
        try repository.database.write { try $0.execute(sql: "PRAGMA max_page_count=2147483646") }
        #expect(try repository.loadSnapshot() == beforeFull)
        #expect(try repository.database.read { try !$0.tableExists("disk_full_fixture") })
        // 独立 SQLite 进程看到同一份已提交代次，避免只验证同进程连接缓存。
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [repository.database.paths.database.path, "SELECT data_revision || ':' || runtime_revision FROM store_metadata"]
        process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(value == "\(beforeFull.revision.data):\(beforeFull.revision.runtime)")

    }

    @Test("数据库快照可恢复，清理不删除锁或素材，坏库不重置")
    func backupAndStorageBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let original = try repository.load()
        let service = StorageMaintenance(database: repository.database)
        let backup = try service.backup(full: true)
        // 外部 SQLite 即使完整性正常，也可能在动态类型列里保存坏值。
        let alteredBackup = try DatabaseQueue(path: backup.appendingPathComponent("app.sqlite").path)
        defer { try? alteredBackup.close() }
        try alteredBackup.write { try $0.execute(sql: "INSERT INTO assets VALUES('invalid', 'assets/media/invalid.jpg', 'invalid')") }
        #expect(throws: (any Error).self) { try service.restore(backup) }
        #expect(try repository.load() == original)
        try alteredBackup.write { try $0.execute(sql: "DELETE FROM assets WHERE digest='invalid'") }
        // SQLite 文件有效而业务列类型损坏时，必须抛错，不能默认重置或触发强制转换崩溃。
        try repository.database.write { try $0.execute(sql: "UPDATE app_preferences SET showDockIcon='invalid'") }
        #expect(throws: (any Error).self) { try repository.load() }
        try service.restore(backup)
        var next = original; next.appearance = .dark
        try repository.save(next)
        try service.restore(backup)
        #expect(try repository.load() == original)
        try service.clearCache(); try service.housekeeping()
        #expect(FileManager.default.fileExists(atPath: repository.database.paths.lock(.app).path))
        let second = SettingsRepository(directoryURL: root)
        #expect(throws: (any Error).self) { try second.load() }
        try repository.database.close()
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("broken database".utf8).write(to: broken.appendingPathComponent("app.sqlite"))
        #expect(throws: (any Error).self) { try SettingsRepository(directoryURL: broken).load() }
        #expect(try Data(contentsOf: broken.appendingPathComponent("app.sqlite")) == Data("broken database".utf8))
        try StorageRecovery.run(source: backup, destination: broken)
        let recovered = SettingsRepository(directoryURL: broken)
        #expect(try recovered.load() == original)
        let originals = try FileManager.default.contentsOfDirectory(at: recovered.database.paths.diagnostics, includingPropertiesForKeys: nil)
        #expect(try originals.contains { try Data(contentsOf: $0) == Data("broken database".utf8) })
        try recovered.database.close()
    }

    @Test("IPC 请求顺序与排队过期")
    @MainActor
    func requestOrdering() throws {
        var sent: [WindowAgentRequest] = []
        var callbacks: [RuntimeAgentXPCClient<WindowAgentRequest, WindowAgentReply>.Completion] = []
        let channel = RuntimeAgentRequestChannel<WindowAgentRequest, WindowAgentReply> { request, completion in
            sent.append(request)
            callbacks.append(completion)
        }
        let capture = WindowAgentRequest(operation: .captureTarget)
        let action = WindowAgentRequest(operation: .performAction, action: .leftHalf)
        var expired = WindowAgentRequest(operation: .fetchState)
        expired.deadline = .distantPast
        var completions = 0
        var expiry: RuntimeAgentIPCError?
        channel.send(capture) { _ in completions += 1 }
        channel.send(action) { _ in completions += 1 }
        channel.send(expired) { if case let .failure(error) = $0 { expiry = error } }
        #expect(sent.map(\.requestID) == [capture.requestID])
        callbacks[0](.failure(.connectionFailed("test")))
        #expect(sent.map(\.requestID) == [capture.requestID, action.requestID])
        callbacks[0](.failure(.connectionFailed("duplicate")))
        #expect(completions == 1)
        callbacks[1](.failure(.connectionFailed("test")))
        #expect(completions == 2)
        #expect(expiry == .requestExpired)
        #expect(sent.count == 2)
        // 停止必须终结在途与排队回调，取消后迟到回包既不重复完成，也不派发旧动作。
        var cancelled = 0
        channel.send(capture) { if case .failure = $0 { cancelled += 1 } }
        channel.send(action) { if case .failure = $0 { cancelled += 1 } }
        channel.cancelAll()
        #expect(cancelled == 2)
        callbacks[2](.success(.init(requestID: capture.requestID)))
        #expect(cancelled == 2 && sent.count == 3)
        channel.send(capture) { _ in }
        #expect(sent.count == 4)
        channel.cancelAll()

    }
}
