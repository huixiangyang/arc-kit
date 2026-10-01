import ArcKitPlatform
import Foundation
@_exported import GRDB

public struct StorageRevision: Sendable, Equatable {
    public let data: Int64
    public let runtime: UInt64
}

public enum ArcKitDatabaseError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let message): message } }
}

/// 一个应用实例只持有一个写连接；Host 使用只读连接，不承担创建或迁移职责。
public final class ArcKitDatabase: @unchecked Sendable {
    public let paths: ArcKitStoragePaths
    private let readonly: Bool
    private let migrate: @Sendable (DatabaseQueue) throws -> Void
    private let prepare: @Sendable () throws -> Void
    private let opening = NSLock()
    private var connection: DatabaseQueue?
    private var processLock: ArcKitProcessLock?

    /// 写连接必须由应用注入迁移，底层不感知 Finder、壁纸或语言等业务表。
    public init(paths: ArcKitStoragePaths, prepare: @escaping @Sendable () throws -> Void = {},
                migrate: @escaping @Sendable (DatabaseQueue) throws -> Void) {
        self.paths = paths
        self.readonly = false
        self.prepare = prepare
        self.migrate = migrate
    }

    public init(reading paths: ArcKitStoragePaths) {
        self.paths = paths
        self.readonly = true
        self.prepare = {}
        self.migrate = { _ in }
    }

    private func queue() throws -> DatabaseQueue {
        opening.lock(); defer { opening.unlock() }
        if let connection { return connection }
        if readonly {
            guard FileManager.default.fileExists(atPath: paths.database.path) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseConfigurationDatabaseNotReady)) }
            try ArcKitStoragePaths.validateFile(paths.database)
        } else {
            try prepare()
            try paths.prepare()
            if processLock == nil {
                guard let lock = ArcKitProcessLock.acquire(for: .app, lockPath: paths.lock(.app).path) else {
                    throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseAnotherAppUsingDataFolder))
                }
                processLock = lock
            }
        }
        do {
            var config = Configuration()
            config.readonly = readonly
            config.busyMode = .timeout(2)
            config.foreignKeysEnabled = true
            let isReadOnly = readonly
            config.prepareDatabase { db in
                if !isReadOnly {
                    try db.execute(sql: "PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL")
                }
            }
            let queue = try DatabaseQueue(path: paths.database.path, configuration: config)
            if readonly {
                try queue.read { db in
                    guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1 else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseSchemaMismatch)) }
                }
            } else {
                let version = try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
                guard version <= 1 else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseDataCreatedNewerVersion)) }
                try migrate(queue)
                try ArcKitStoragePaths.secureFile(paths.database)
            }
            connection = queue
            return queue
        } catch { throw error }
    }

    /// 恢复先保留写者锁，即使原库损坏也不能在准备资源时让另一实例进入。
    public func reserveForRecovery() throws {
        guard !readonly else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseReadOnlyRestoreRejected)) }
        opening.lock(); defer { opening.unlock() }
        try paths.prepare()
        if processLock == nil {
            guard let lock = ArcKitProcessLock.acquire(for: .app, lockPath: paths.lock(.app).path) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseAppStillUsingData)) }
            processLock = lock
        }
    }

    public func close() throws {
        opening.lock(); defer { opening.unlock() }
        try connection?.close(); connection = nil; processLock = nil
    }

    public func read<T>(_ body: (Database) throws -> T) throws -> T { try queue().read(body) }
    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        guard !readonly else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseReadOnly)) }
        return try queue().write(body)
    }
    public static func revision(_ db: Database) throws -> StorageRevision {
        guard let row = try Row.fetchOne(db, sql: "SELECT data_revision,runtime_revision FROM store_metadata WHERE id=1") else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseDatabaseMetadataMissing)) }
        guard let data = Int64.fromDatabaseValue(row[0]), let runtime = Int64.fromDatabaseValue(row[1]), data >= 0, runtime >= 0 else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseInvalidConfigurationRevision)) }
        return StorageRevision(data: data, runtime: UInt64(runtime))
    }
    @discardableResult public static func advance(_ db: Database, runtime: Bool = false) throws -> StorageRevision {
        try db.execute(sql: "UPDATE store_metadata SET data_revision=data_revision+1, runtime_revision=runtime_revision+? WHERE id=1", arguments: [runtime ? 1 : 0])
        return try revision(db)
    }

    public func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseBackupDestinationAlreadyExists)) }
        try ArcKitStoragePaths.secureDirectory(url.deletingLastPathComponent())
        let destination = try DatabaseQueue(path: url.path)
        try queue().backup(to: destination)
        try destination.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseBackupIntegrityCheckFailed)) }
        }
        try destination.close()
        try ArcKitStoragePaths.secureFile(url)
    }

    /// 恢复由组合层停掉消费者后调用。连接在独占临界区内关闭、替换、重新打开。
    public func restore(from url: URL, transform: (Database) throws -> Void = { _ in }) throws {
        guard !readonly else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseReadOnlyRestoreFailed)) }
        var config = Configuration(); config.readonly = true
        let input = try DatabaseQueue(path: url.path, configuration: config)
        try input.read { db in
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                  try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseBackupVersionIntegrityMismatch)) }
        }
        try paths.prepare()
        let folder = try paths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let candidate = folder.appendingPathComponent("app.sqlite")
        let output = try DatabaseQueue(path: candidate.path)
        try input.backup(to: output)
        try output.write(transform)
        try output.close(); try input.close()
        try ArcKitStoragePaths.secureFile(candidate)
        opening.lock(); defer { opening.unlock() }
        if processLock == nil {
            guard let lock = ArcKitProcessLock.acquire(for: .app, lockPath: paths.lock(.app).path) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.databaseAppStillUsingDatabase)) }
            processLock = lock
        }
        try connection?.close()
        connection = nil
        let preserved = paths.diagnostics.appendingPathComponent("before-restore-\(UUID().uuidString).sqlite")
        if FileManager.default.fileExists(atPath: paths.database.path) {
            try FileManager.default.copyItem(at: paths.database, to: preserved)
            try ArcKitStoragePaths.secureFile(preserved)
            // 若旧库崩溃留下 journal，连同原库保存；不能把旧 journal 应用到新库。
            var moved: [(URL, URL)] = []
            do {
            for suffix in ["-journal", "-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: paths.database.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    let copy = URL(fileURLWithPath: preserved.path + suffix)
                    try FileManager.default.moveItem(at: sidecar, to: copy)
                    moved.append((sidecar, copy))
                }
            }
            _ = try FileManager.default.replaceItemAt(paths.database, withItemAt: candidate)
            } catch {
                for (original, copy) in moved { try FileManager.default.moveItem(at: copy, to: original) }
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: candidate, to: paths.database)
        }
        try ArcKitStoragePaths.secureFile(paths.database)
        try ArcKitStoragePaths.synchronizeDirectory(paths.root)
    }

    /// 通用存储元数据；业务 schema 由应用迁移在同一事务中创建。
    public static func createStoreSchema(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE store_metadata (id INTEGER PRIMARY KEY CHECK(id=1), data_revision INTEGER NOT NULL CHECK(data_revision>=0), runtime_revision INTEGER NOT NULL CHECK(runtime_revision>=0)); INSERT INTO store_metadata VALUES (1,0,0)")
        try db.execute(sql: "CREATE TABLE domain_revisions(domain TEXT PRIMARY KEY, revision INTEGER NOT NULL); CREATE TABLE assets (digest TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, byte_count INTEGER NOT NULL CHECK(byte_count>0))")
        try db.execute(sql: "PRAGMA user_version=1")
    }
}
