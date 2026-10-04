@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitWindow
import CoreGraphics
import Foundation
import Testing

@Suite("窗口场景事务与迁移")
struct WindowSceneStorageTests {
    @Test("旧SQLite只补空场景表，场景与其他窗口偏好原子保存、只读可见、重启及备份保留")
    func migrationTransactionAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var before = try repository.load()
        before.windowManagement.windowGap = 12
        before.windowManagement.dragSnapEnabled = false
        let previous = try repository.save(before)
        // 模拟未加入场景功能的真实表结构，而非只给新模型填默认值。
        try repository.database.write { db in
            try db.execute(sql: "DROP TABLE window_scenes")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='window-scenes-v1'")
        }
        try repository.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        #expect(migrated.settings == before)
        #expect(migrated.revision.runtime == previous.revision.runtime + 1)

        let display = WindowSceneDisplay(id: UUID().uuidString, name: "External", visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let entry = WindowSceneEntry(bundleIdentifier: "test.editor", applicationName: "Editor", savedTitle: "Project",
                                    titleMatchMode: .contains, titleMatchValue: "Project", displayID: display.id,
                                    normalizedFrame: .init(x: 0, y: 0, width: 0.65, height: 1))
        var edited = before
        edited.windowManagement.scenes = [.init(name: "开发", displays: [display], entries: [entry], focusEntryID: entry.id,
                                                shortcut: .init(keyCode: 18, keyEquivalent: "1", modifiers: [.control, .option, .command]))]
        edited.windowManagement.windowGap = 8
        try upgraded.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_scene BEFORE INSERT ON window_scenes BEGIN SELECT RAISE(FAIL, 'injected scene failure'); END")
        }
        #expect(throws: (any Error).self) { try upgraded.save(edited) }
        #expect(try upgraded.loadSnapshot() == migrated)
        try upgraded.database.write { try $0.execute(sql: "DROP TRIGGER reject_scene") }
        let committed = try upgraded.save(edited)
        #expect(committed.revision.runtime == migrated.revision.runtime + 1)
        let reader = ArcKitDatabase(reading: upgraded.database.paths)
        #expect(try reader.read { db in
            try ArcKitRecord.load(WindowManagementSettings.self, layout: WindowManagementSettings.recordLayout, db: db) == edited.windowManagement
        })
        try reader.close()
        let backup = try StorageMaintenance(database: upgraded.database).backup(full: true)
        try upgraded.save(before)
        try StorageMaintenance(database: upgraded.database).restore(backup)
        #expect(try upgraded.load() == edited)
        try upgraded.database.close()
        let restarted = SettingsRepository(directoryURL: root)
        #expect(try restarted.load() == edited)
        let reopenedRevision = try restarted.loadSnapshot().revision
        try restarted.database.close()
        let secondRestart = SettingsRepository(directoryURL: root)
        #expect(try secondRestart.loadSnapshot().revision == reopenedRevision)
        #expect(try secondRestart.load() == edited)
        try secondRestart.database.close()
    }

    @Test("JSON备份只接受当前schema，窗口场景完整往返")
    func strictBackupSchema() throws {
        var current = AppSettings.defaults
        let display = WindowSceneDisplay(id: UUID().uuidString, name: "Built-in", visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850))
        let entry = WindowSceneEntry(bundleIdentifier: "test.editor", applicationName: "Editor", savedTitle: "Project",
                                    titleMatchMode: .exact, titleMatchValue: "Project", displayID: display.id,
                                    normalizedFrame: .init(x: 0, y: 0, width: 1, height: 1))
        current.windowManagement.scenes = [.init(name: "Develop", displays: [display], entries: [entry], focusEntryID: entry.id)]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(current)) == current)
        var old = current
        old.schemaVersion -= 1
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(old))
        }
    }
}
