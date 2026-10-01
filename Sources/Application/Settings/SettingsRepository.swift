import ArcKitFinder
import ArcKitPlatform
import ArcKitPersistence
import ArcKitMouse
import ArcKitWindow
import Foundation

public struct CommittedSettings: Sendable, Equatable {
    public let settings: AppSettings
    public let revision: StorageRevision
}

/// 同步事务只允许在后台任务中调用。数据库提交与后台应用回执是两条独立状态链。
public final class SettingsRepository: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("com.archalo.arckit.settings-repository.didChange")
    public let database: ArcKitDatabase
    public var directoryURL: URL { database.paths.root }
    public init(database: ArcKitDatabase) { self.database = database }
    public convenience init() { self.init(database: ApplicationStorage.database) }
    public convenience init(directoryURL: URL) { self.init(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: directoryURL))) }
    public static func defaultDirectoryURL() -> URL { ArcKitStoragePaths.current.root }

    public func loadSnapshot() throws -> CommittedSettings {
        try database.read { db in
            return CommittedSettings(settings: try Self.read(db), revision: try ArcKitDatabase.revision(db))
        }
    }
    public func load() throws -> AppSettings { try loadSnapshot().settings }
    @discardableResult public func save(_ settings: AppSettings) throws -> CommittedSettings {
        guard try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings else {
            throw SettingsRepositoryError.transactionFailed(L10n.string(.Settings.repositoryConfigurationBusinessValidationFailed))
        }
        let snapshot = try database.write { db in
            let current = try Self.read(db)
            guard current != settings else { return CommittedSettings(settings: current, revision: try ArcKitDatabase.revision(db)) }
            let runtimeChanged = current.language != settings.language || current.finder != settings.finder || !current.mouseEnhancement.hasSameRuntimeConfiguration(as: settings.mouseEnhancement) || current.windowManagement != settings.windowManagement
            try Self.store(settings, db: db)
            guard try Self.read(db) == settings else { throw SettingsRepositoryError.transactionFailed(L10n.string(.Settings.repositoryTransactionReadbackMismatch)) }
            return CommittedSettings(settings: settings, revision: try ArcKitDatabase.advance(db, runtime: runtimeChanged))
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return snapshot
    }
    public func reset() throws { try save(.defaults) }

    static func read(_ db: Database) throws -> AppSettings {
        guard let global = try ArcKitRecord.load(GlobalSettings.self, layout: GlobalSettings.recordLayout, db: db),
              let finder = try ArcKitRecord.load(FinderRuntimeSettings.self, layout: FinderRuntimeSettings.recordLayout, db: db),
              let window = try ArcKitRecord.load(WindowManagementSettings.self, layout: WindowManagementSettings.recordLayout, db: db),
              let mouse = try ArcKitRecord.load(MouseEnhancementSettings.self, layout: MouseEnhancementSettings.recordLayout, db: db) else {
            throw ArcKitDatabaseError.message(L10n.string(.Settings.repositoryIncompleteSettings))
        }
        var value = AppSettings(finder: finder)
        global.apply(to: &value); value.windowManagement = window; value.mouseEnhancement = mouse
        return value
    }
    static func store(_ value: AppSettings, db: Database) throws {
        try ArcKitRecord.save(GlobalSettings(appSettings: value), layout: GlobalSettings.recordLayout, db: db)
        try ArcKitRecord.save(value.finder, layout: FinderRuntimeSettings.recordLayout, db: db)
        try ArcKitRecord.save(value.windowManagement, layout: WindowManagementSettings.recordLayout, db: db)
        try ArcKitRecord.save(value.mouseEnhancement, layout: MouseEnhancementSettings.recordLayout, db: db)
    }
}
