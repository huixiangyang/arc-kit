import ArcKitPlatform
import ArcKitPersistence
import ArcKitFinder
import ArcKitWindow
import ArcKitMouse
import Foundation

/// 业务表、约束与历史修复由应用拥有；迁移标识和顺序属于已发布的数据契约。
enum ApplicationStorageMigrations {
    static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        let layouts = [GlobalSettings.recordLayout, FinderRuntimeSettings.recordLayout,
            WindowManagementSettings.recordLayout, MouseEnhancementSettings.recordLayout,
            WallpaperCatalog.recordLayout, AppBackgroundSettings.recordLayout, WallpaperSourceConfiguration.recordLayout]
        migrator.registerMigration("storage-v1") { db in
            try ArcKitDatabase.createStoreSchema(in: db)
            for layout in layouts { try createRecords(layout, in: db) }
            if layouts.contains(where: { $0.table == "wallpaper_preferences" }) {
                try db.execute(sql: "CREATE UNIQUE INDEX wallpaper_item_id ON wallpaper_items(id); CREATE TABLE display_wallpapers(display_id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES wallpaper_items(id) DEFERRABLE INITIALLY DEFERRED, scaling TEXT NOT NULL)")
            }
            for (table, field) in [("finder_modules", "moduleID"), ("file_templates", "id"), ("favorite_directories", "id"), ("favorite_applications", "id"), ("window_hotkeys", "action"), ("window_application_rules", "bundleIdentifier"), ("mouse_application_rules", "bundleIdentifier"), ("wallpaper_sources", "url")] {
                if try db.tableExists(table) { try db.execute(sql: "CREATE UNIQUE INDEX \(table)_identity ON \(table)(\(field))") }
            }
            try SettingsRepository.store(.defaults, db: db)
            try ArcKitRecord.save(WallpaperCatalog(), layout: WallpaperCatalog.recordLayout, db: db)
            try ArcKitRecord.save(AppBackgroundSettings(), layout: AppBackgroundSettings.recordLayout, db: db)
            try ArcKitRecord.save(WallpaperSourceConfiguration(), layout: WallpaperSourceConfiguration.recordLayout, db: db)
            try ArcKitDatabase.advance(db, runtime: true)
        }
        migrator.registerMigration("finder-menu-selection-v1") { db in
            guard try db.tableExists("finder_modules") else { return }
            // build 45 曾误删三项选择状态；仅补回缺失值，已有用户勾选和取消勾选原样保留。
            try db.execute(sql: "UPDATE finder_modules SET enabled=1, _types=json_set(_types, '$.enabled', 'bool') WHERE moduleID IN ('newFile', 'favoriteApps', 'favoriteDirectories') AND enabled IS NULL")
            if db.changesCount > 0 { try ArcKitDatabase.advance(db, runtime: true) }
        }
        migrator.registerMigration("application-language-v1") { db in
            guard try db.tableExists("app_preferences") else { return }
            // 只迁移数据库结构；语言不写入独立偏好文件，保持配置的单一来源。
            if try !db.columns(in: "app_preferences").contains(where: { $0.name == "language" }) {
                try db.execute(sql: "ALTER TABLE app_preferences ADD COLUMN language TEXT")
            }
            try db.execute(sql: "UPDATE app_preferences SET language='system', _types=json_set(_types, '$.language', 'text') WHERE language IS NULL")
            if db.changesCount > 0 { try ArcKitDatabase.advance(db, runtime: true) }
            if try db.tableExists("wallpaper_source_preferences") {
                try db.execute(sql: "UPDATE wallpaper_source_preferences SET disabled=replace(disabled, 'image:Bing 每日壁纸', 'image:Bing')") // i18n-ignore: 持久化 ID 迁移
            }
        }
        migrator.registerMigration("background-aura-v1") { db in
            let columns = try db.columns(in: "background_preferences").map(\.name)
            if !columns.contains("aura") {
                try db.execute(sql: "ALTER TABLE background_preferences ADD COLUMN aura TEXT")
                let enabled = try Bool.fetchOne(db, sql: "SELECT motionEnabled FROM background_preferences") ?? false
                var aura = AuraSettings()
                var theme = AuraTheme.amber
                theme.motion = enabled ? .slow : .still
                theme.particles = enabled ? 0.5 : 0
                aura.draft = theme
                let encoded = String(decoding: try JSONEncoder().encode(aura), as: UTF8.self)
                try db.execute(sql: "UPDATE background_preferences SET aura=?, _types=json_set(json_remove(_types, '$.motionEnabled'), '$.aura', 'json')", arguments: [encoded])
                // 旧动效列只用于这次迁移，运行时不保留双重配置。
                try db.execute(sql: "ALTER TABLE background_preferences DROP COLUMN motionEnabled")
                try ArcKitDatabase.advance(db)
            }
            for child in AppBackgroundSettings.recordLayout.children.values { try createRecords(child, in: db) }
        }
        migrator.registerMigration("menu-bar-visibility-v1") { db in
            if try !db.columns(in: "app_preferences").contains(where: { $0.name == "showMenuBarIcon" }) {
                try db.execute(sql: "ALTER TABLE app_preferences ADD COLUMN showMenuBarIcon ANY")
            }
            // 旧安装继续显示入口；只补缺失值，恢复备份时不能覆盖用户保存的隐藏选择。
            try db.execute(sql: "UPDATE app_preferences SET showMenuBarIcon=1, _types=json_set(_types, '$.showMenuBarIcon', 'bool') WHERE showMenuBarIcon IS NULL")
            if db.changesCount > 0 { try ArcKitDatabase.advance(db) }
        }
        migrator.registerMigration("mouse-uu-remote-rule-v1") { db in
            let rule = MouseAppScrollProfile.uuRemoteDefault
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM mouse_application_rules WHERE bundleIdentifier=?", arguments: [rule.bundleIdentifier]) == 0 else { return }
            // 使用此迁移发布时的列，不解码后续版本的模型；已有规则保留，后续迁移再补新字段。
            let tuning = String(decoding: try JSONEncoder().encode(rule.tuning), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO mouse_application_rules (_position, _types, id, displayName, bundleIdentifier, behavior, tuning)
                SELECT coalesce(max(_position), -1) + 1,
                    '{"id":"text","displayName":"text","bundleIdentifier":"text","behavior":"text","tuning":"json"}',
                    ?, ?, ?, ?, ? FROM mouse_application_rules
                """, arguments: [rule.id.uuidString, rule.displayName, rule.bundleIdentifier, rule.behavior.rawValue, tuning])
            try ArcKitDatabase.advance(db, runtime: true)
        }
        migrator.registerMigration("mouse-rule-note-v1") { db in
            if try !db.columns(in: "mouse_application_rules").contains(where: { $0.name == "note" }) {
                try db.execute(sql: "ALTER TABLE mouse_application_rules ADD COLUMN note ANY")
            }
            let rule = MouseAppScrollProfile.uuRemoteDefault
            // 只为仍采用预置行为的原始 UU 规则补说明；用户自建、修改或删除的规则不猜测用途。
            try db.execute(sql: """
                UPDATE mouse_application_rules SET note=CASE
                    WHEN id=? AND bundleIdentifier=? AND behavior='system' THEN ? ELSE '' END,
                    _types=json_set(_types, '$.note', 'text') WHERE note IS NULL
                """, arguments: [rule.id.uuidString, rule.bundleIdentifier, rule.note])
            if db.changesCount > 0 { try ArcKitDatabase.advance(db) }
        }
        try migrator.migrate(queue)
    }

    private static func createRecords(_ layout: ArcKitRecordLayout, in db: Database) throws {
        let constraints: [String: String]
        switch layout.table {
        case "wallpaper_items":
            constraints = ["digest": "NOT NULL REFERENCES assets(digest) DEFERRABLE INITIALLY DEFERRED"]
        case "background_preferences":
            constraints = ["imageID": "REFERENCES assets(digest) DEFERRABLE INITIALLY DEFERRED"]
        default: constraints = [:]
        }
        try ArcKitRecord.createTable(layout, in: db, columnConstraints: constraints)
        for child in layout.children.values { try createRecords(child, in: db) }
    }
}
