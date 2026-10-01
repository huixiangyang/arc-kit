import ArcKitPlatform
import ArcKitPersistence
import Foundation

/// 主应用组合根。所有业务 store 注入同一个连接，独立测试只注入自己的临时根。
enum ApplicationStorage {
    static let database = makeDatabase(paths: .current)
    static func makeDatabase(paths: ArcKitStoragePaths) -> ArcKitDatabase {
        ArcKitDatabase(paths: paths, prepare: {
            #if !DEBUG
            let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc Kit/Settings")
            if paths == .current, !FileManager.default.fileExists(atPath: paths.database.path), FileManager.default.fileExists(atPath: legacy.path) {
                throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageLegacyDataDetectedQuitOldVersion))
            }
            #endif
        }, migrate: ApplicationStorageMigrations.migrate)
    }
}

/// AppKit 生命周期创建前完成存储初始化；第二个实例不会创建菜单、Host 或默认草稿。
public enum StorageBootstrap {
    public static func prepare() throws {
        _ = try SettingsRepository(database: ApplicationStorage.database).loadSnapshot()
        do { try StorageMaintenance(database: ApplicationStorage.database).housekeeping() }
        catch { ArcKitLog.append("storage housekeeping failed: \(error.localizedDescription)") }
    }
}
