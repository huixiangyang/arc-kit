import ArcKitPlatform
import ArcKitPersistence
import ArcKitFinder
import ArcKitFinderRuntime
@testable import ArcKitApplication
import Foundation
import Testing

@Suite("国际化资源与跨进程配置")
struct LocalizationTests {
    @Test("原生资源支持语言切换、复数和参数重排，用户文本原样保留")
    func nativeCatalogFormatting() {
        #expect(L10n.string(.Common.cancel, language: .english) == "Cancel")
        #expect(L10n.string(.Common.cancel, language: .simplifiedChinese) == "取消")
        #expect(L10n.string(.Wallpaper.libraryCount(1), language: .english) == "1 wallpaper")
        #expect(L10n.string(.Wallpaper.libraryCount(2), language: .english) == "2 wallpapers")
        #expect(L10n.string(.Wallpaper.libraryCount(0), language: .simplifiedChinese) == "0 项壁纸")
        let name = "我的 {0} 100%.png"
        #expect(L10n.string(.WallpaperPlayback.applySucceeded(name, "Display 1", "Wallpaper"), language: .english)
            == "Set “我的 {0} 100%.png” as the Wallpaper for Display 1.")
        #expect(L10n.string(.WallpaperMedia.loopOutputDuration(1.25), language: .english) == "Output: 1.2 seconds")
        #expect(ArcKitLanguage.system.resolved(preferredLanguages: ["zh-TW", "en-US"]) == .simplifiedChinese)
        #expect(ArcKitLanguage.system.resolved(preferredLanguages: ["fr-FR"]) == .english)
        #expect(ArcKitLanguage.english.resolved(preferredLanguages: ["zh-CN"]) == .english)
        // 功能移动后，入口不能丢失或重复；中英文搜索词仍路由到同一个功能。
        #expect(Set(ApplicationFeatureCatalog.all.map(\.section)) == Set(MainWindowSection.allCases))
        let commands = ArcKitQuickCommandCatalog.all
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(ArcKitQuickCommandCatalog.results(for: "NEW FILE").first?.action == .finder(.templates))
        #expect(ArcKitQuickCommandCatalog.results(for: "透明度").contains { $0.action == .preferences(.background) })

    }

    @Test("语言事务推进后台代次，旧数据库迁移保留已有设置")
    func languageMigrationAndRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var settings = try repository.load()
        settings.appearance = .dark
        settings.finder.menuConfiguration.favoriteDirectories = [FavoriteDirectory(name: "我的项目 {0}", path: root.path)]
        let original = try repository.save(settings)
        settings.language = .english
        let saved = try repository.save(settings)
        #expect(saved.revision.runtime == original.revision.runtime + 1)
        #expect(try repository.load().language == .english)
        // 模拟语言功能之前的 SQLite 列及迁移记录，不接触实际用户配置。
        try repository.database.write { db in
            try db.execute(sql: "ALTER TABLE app_preferences DROP COLUMN language")
            try db.execute(sql: "UPDATE app_preferences SET _types=json_remove(_types, '$.language')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='application-language-v1'")
        }
        try repository.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        let migrated = try reopened.load()
        #expect(migrated.language == .system)
        #expect(migrated.appearance == .dark)
        #expect(migrated.finder == settings.finder)
        var english = migrated; english.language = .english
        try reopened.database.write { try $0.execute(sql: "CREATE TRIGGER reject_language BEFORE INSERT ON app_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        #expect(throws: (any Error).self) { try reopened.save(english) }
        #expect(try reopened.load() == migrated)
    }

    @Test("Finder 快照和独立 Worker 显式传递语言，拒绝旧协议")
    func languageIPC() throws {
        let snapshot = FinderExtensionSnapshot(language: .english)
        #expect(try JSONDecoder().decode(FinderExtensionSnapshot.self, from: JSONEncoder().encode(snapshot)).language == .english)
        var oldSnapshot = snapshot; oldSnapshot.schemaVersion -= 1
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FinderExtensionSnapshot.self, from: JSONEncoder().encode(oldSnapshot)) }
        var command = FinderCommandRequest(payload: .copyPaths(FinderPathPayload(sourcePaths: ["/tmp/a"])))
        // 协议用毫秒传输时间；固定整毫秒，避免浮点换算影响语言传递断言。
        command.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        command.context.requestedAt = command.createdAt
        let worker = FinderOperationWorkerRequest(command: command, settings: .defaults, language: .english)
        let decoded = try FinderOperationWorkerCodec.decode(FinderOperationWorkerRequest.self, from: FinderOperationWorkerCodec.encode(worker))
        #expect(decoded.language == .english)
        #expect(decoded.command == command)
        var oldWorker = worker; oldWorker.version -= 1
        #expect(throws: FinderOperationWorkerError.self) { try oldWorker.validate() }
    }
}
