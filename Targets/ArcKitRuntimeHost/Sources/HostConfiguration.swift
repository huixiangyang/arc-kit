import Foundation
import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import ArcKitWindow
import ArcKitMouse

/// SQL 一次事务读取三项功能；Finder 执行回调只取内存快照，不阻塞主线程或事件监听。
final class HostConfiguration: @unchecked Sendable {
    struct Snapshot: Sendable {
        let language: ArcKitLanguage
        let window: WindowManagementSettings
        let mouse: MouseEnhancementSettings
        let finder: FinderRuntimeSettings
        let revision: UInt64
    }
    private let database: ArcKitDatabase
    init(database: ArcKitDatabase) { self.database = database }
    private let lock = NSLock()
    private var finder: FinderRuntimeSettings = {
        var value = FinderRuntimeSettings.defaults; value.menuConfiguration.isEnabled = false; return value
    }()
    func finderSettings() -> FinderRuntimeSettings { lock.lock(); defer { lock.unlock() }; return finder }
    func publish(_ value: FinderRuntimeSettings) { lock.lock(); defer { lock.unlock() }; finder = value }
    func read() throws -> Snapshot {
        try database.read { db in
            guard let window = try ArcKitRecord.load(WindowManagementSettings.self, layout: WindowManagementSettings.recordLayout, db: db),
                  let mouse = try ArcKitRecord.load(MouseEnhancementSettings.self, layout: MouseEnhancementSettings.recordLayout, db: db),
                  let finder = try ArcKitRecord.load(FinderRuntimeSettings.self, layout: FinderRuntimeSettings.recordLayout, db: db) else {
                throw ArcKitDatabaseError.message(L10n.string(.HostEntry.hostCommittedConfigurationIncomplete))
            }
            guard let rawLanguage = try String.fetchOne(db, sql: "SELECT language FROM app_preferences LIMIT 1"),
                  let language = ArcKitLanguage(rawValue: rawLanguage) else {
                throw ArcKitDatabaseError.message(L10n.string(.HostEntry.hostInvalidLanguageConfiguration))
            }
            return Snapshot(language: language, window: window, mouse: mouse, finder: finder, revision: try ArcKitDatabase.revision(db).runtime)
        }
    }
}
