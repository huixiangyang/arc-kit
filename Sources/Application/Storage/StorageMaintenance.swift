import ArcKitFinder
import ArcKitPlatform
import ArcKitPersistence
import Foundation

struct StorageUsage: Identifiable, Sendable {
    enum Kind: Sendable {
        case database, assets, logs, cache, backups, diagnostics
        var title: String {
            switch self {
            case .database: L10n.string(.DataManagement.storageDatabase)
            case .assets: L10n.string(.DataManagement.storageAssets)
            case .logs: L10n.string(.DataManagement.storageLogs)
            case .cache: L10n.string(.DataManagement.storageCache)
            case .backups: L10n.string(.DataManagement.storageBackups)
            case .diagnostics: L10n.string(.DataManagement.storageDiagnostics)
            }
        }
    }
    let kind: Kind
    let bytes: Int64
    var id: Kind { kind }
}

enum StorageOperation: Sendable {
    case export(URL), restore(URL), clearCache

    var isRestore: Bool { if case .restore = self { true } else { false } }
    var progress: String {
        switch self {
        case .export: L10n.string(.DataManagement.storageExportingAllData)
        case .restore: L10n.string(.DataManagement.storageValidatingRestoringBackup)
        case .clearCache: L10n.string(.DataManagement.storageClearingCache)
        }
    }

    func perform(using service: StorageMaintenance) throws -> (message: String, exportedURL: URL?) {
        switch self {
        case let .export(url):
            let saved = try service.backup(full: true, destination: url)
            return (L10n.string(.DataManagement.storageAllDataExported), saved)
        case let .restore(url):
            try service.restore(url)
            return (L10n.string(.DataManagement.storageDataRestored), nil)
        case .clearCache:
            try service.clearCache()
            return (L10n.string(.DataManagement.storageCacheCleared), nil)
        }
    }
}

struct StorageBackupManifest: Codable, Sendable {
    struct File: Codable, Sendable { let path: String; let digest: String; let bytes: Int64; let isDirectory: Bool }
    let format: Int
    let createdAt: Date
    let includesAssets: Bool
    let files: [File]
}

/// 由显式用户操作触发，不创建常驻清理进程；永远不触碰 runtime 锁与接收凭证。
struct StorageMaintenance: Sendable {
    let database: ArcKitDatabase
    var paths: ArcKitStoragePaths { database.paths }

    func usage() throws -> [StorageUsage] {
        let locations: [(StorageUsage.Kind, URL)] = [(.database, paths.database), (.assets, paths.root.appendingPathComponent("assets")),
            (.logs, paths.logs), (.cache, paths.cache), (.backups, paths.backups), (.diagnostics, paths.diagnostics)]
        return try locations.map { kind, url in
            StorageUsage(kind: kind, bytes: try files(under: url).reduce(Int64(0)) { $0 + $1.bytes })
        }
    }
    func clearCache() throws {
        // 下载任务位于 tmp；更新包不在普通清缓存操作内，避免破坏安装中的文件。
        for directory in [paths.thumbnails, paths.remote] {
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    func housekeeping() throws {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: paths.temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let date = values.contentModificationDate, Date().timeIntervalSince(date) > 86400 else { continue }
            // 无法读到身份就保留，不把无法判断当作“无主”。
            let ownerFile = url.appendingPathComponent("owner.json")
            guard let data = try? Data(contentsOf: ownerFile), let owner = try? JSONDecoder().decode(RuntimeHostSession.self, from: data), !owner.isOwnerAlive else { continue }
            try fm.removeItem(at: url)
        }
        try retain(in: paths.diagnostics, count: 10, days: 30)
        let cacheFiles = try (files(under: paths.remote) + files(under: paths.thumbnails)).filter { !$0.isDirectory }.sorted { $0.modified < $1.modified }
        var total = cacheFiles.reduce(Int64(0)) { $0 + $1.bytes }
        for file in cacheFiles where total > 512 * 1_024 * 1_024 { try fm.removeItem(at: file.url); total -= file.bytes }
    }
    @discardableResult func backup(full: Bool, destination: URL? = nil) throws -> URL {
        let target = destination ?? paths.backups.appendingPathComponent("snapshot-\(UUID().uuidString).arckitbackup")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupDestinationAlreadyExistsChooseNew)) }
        let staging = try paths.makeTemporaryDirectory()
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }
        try database.backup(to: staging.appendingPathComponent("app.sqlite"))
        var manifest: [StorageBackupManifest.File] = []
        for file in try files(under: paths.root.appendingPathComponent("assets")) {
            let normalized = file.url.standardizedFileURL.path
            guard normalized.hasPrefix(paths.root.path + "/") else { throw StoragePathError.unsafePath(normalized) }
            let relative = String(normalized.dropFirst(paths.root.path.count + 1))
            manifest.append(.init(path: relative, digest: file.isDirectory ? "" : try ArcKitAssetStore.digest(file.url), bytes: file.bytes, isDirectory: file.isDirectory))
            if full {
                let output = staging.appendingPathComponent(relative)
                try ArcKitStoragePaths.secureDirectory(output.deletingLastPathComponent())
                if file.isDirectory { try ArcKitStoragePaths.secureDirectory(output) }
                else {
                    try FileManager.default.copyItem(at: file.url, to: output)
                    try ArcKitStoragePaths.secureFile(output)
                }
            }
        }
        let snapshot = StorageBackupManifest(format: 1, createdAt: Date(), includesAssets: full, files: manifest)
        try validateSnapshot(staging.appendingPathComponent("app.sqlite"), manifest: snapshot)
        try FileManager.default.removeItem(at: staging.appendingPathComponent("owner.json"))
        try ArcKitAtomicFile.writeAtomically(JSONEncoder().encode(snapshot), to: staging.appendingPathComponent("manifest.json"))
        // 用户选择的导出父目录不属于应用，不能修改其权限。跨卷由 Foundation 完成复制后移除。
        try FileManager.default.moveItem(at: staging, to: target)
        completed = true
        if destination == nil { try retain(in: paths.backups, count: 7, days: nil, prefix: "snapshot-") }
        return target
    }
    func restore(_ source: URL) throws {
        try database.reserveForRecovery()
        let data = try ArcKitBoundedFileReader.read(from: source.appendingPathComponent("manifest.json"), maximumBytes: 8 * 1_024 * 1_024)
        let manifest = try JSONDecoder().decode(StorageBackupManifest.self, from: data)
        guard manifest.format == 1, manifest.files.count <= 20_000 else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageInvalidBackupFormat)) }
        // 先完整验证，任何资源缺失都不改数据库。元数据备份必须仍能找到原媒体。
        for entry in manifest.files {
            guard entry.path.hasPrefix("assets/"), entry.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !entry.path.contains("\\") else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupContainsOutBoundsPath)) }
            let file = (manifest.includesAssets ? source : paths.root).appendingPathComponent(entry.path)
            guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path else { throw StoragePathError.unsafePath(file.path) }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let digest = entry.isDirectory ? "" : try ArcKitAssetStore.digest(file)
            guard entry.isDirectory
                ? (values.isDirectory == true && entry.bytes == 0 && entry.digest.isEmpty)
                : (values.isDirectory != true && Int64(values.fileSize ?? -1) == entry.bytes && digest == entry.digest)
            else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupAssetMissingVerificationFailed(String(describing: entry.path)))) }
        }
        // 先在隔离副本执行一次性迁移，旧备份保持原样，当前库仍未被替换。
        let staging = try paths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent("app.sqlite")
        try prepareRestoreSnapshot(source.appendingPathComponent("app.sqlite"), at: snapshot)
        try validateSnapshot(snapshot, manifest: manifest)
        // 保留当前库恢复点；SQLite backup API 不直接复制正在使用的数据库文件。
        // 正常库留下可直接选择的快照；损坏库仍允许恢复，原始字节由 restore 独占保存。
        do { _ = try backup(full: false) }
        catch { ArcKitLog.append("pre-restore snapshot unavailable; original database will be preserved: \(error.localizedDescription)") }
        if manifest.includesAssets {
            for entry in manifest.files {
                let target = paths.root.appendingPathComponent(entry.path)
                if entry.isDirectory { try ArcKitStoragePaths.secureDirectory(target); continue }
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try ArcKitAssetStore.digest(target) == entry.digest else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageLocalAssetConflictsBackupOriginalFile)) }
                } else {
                    try ArcKitStoragePaths.secureDirectory(target.deletingLastPathComponent())
                    try FileManager.default.copyItem(at: source.appendingPathComponent(entry.path), to: target)
                    try ArcKitStoragePaths.secureFile(target)
                }
            }
        }
        try database.restore(from: snapshot) { db in
            var settings = try SettingsRepository.read(db)
            for index in settings.finder.menuConfiguration.fileTemplates.indices {
                guard case .managedUserFile(let path) = settings.finder.menuConfiguration.fileTemplates[index].templateSource else { continue }
                let relative = try templateRelativePath(path)
                guard manifest.files.contains(where: { $0.path == relative }) else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupLacksCustomTemplates)) }
                settings.finder.menuConfiguration.fileTemplates[index].templateSource = .managedUserFile(paths.root.appendingPathComponent(relative).path)
            }
            try SettingsRepository.store(settings, db: db)
        }
    }
    private func templateRelativePath(_ path: String) throws -> String {
        guard let marker = path.range(of: "/assets/templates/"),
              !path.split(separator: "/").contains("..") else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageCustomTemplatePathOutsideManaged)) }
        return "assets/templates/" + path[marker.upperBound...]
    }
    private func prepareRestoreSnapshot(_ source: URL, at destination: URL) throws {
        var config = Configuration(); config.readonly = true
        let input = try DatabaseQueue(path: source.path, configuration: config)
        defer { try? input.close() }
        try input.read { db in
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                  try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try db.tableExists("grdb_migrations"),
                  try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations WHERE identifier='storage-v1'") != nil else {
                throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupDatabaseVersionIntegrityInvalid))
            }
        }
        let output = try DatabaseQueue(path: destination.path)
        defer { try? output.close() }
        try input.backup(to: output)
        try ApplicationStorageMigrations.migrate(output)
        try ArcKitStoragePaths.secureFile(destination)
    }

    private func validateSnapshot(_ url: URL, manifest: StorageBackupManifest) throws {
        guard Set(manifest.files.map(\.path)).count == manifest.files.count else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupManifestContainsDuplicateAssets)) }
        var config = Configuration(); config.readonly = true
        let candidate = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? candidate.close() }
        try candidate.read { db in
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                  try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupDatabaseVersionIntegrityInvalid)) }
            let settings = try SettingsRepository.read(db)
            guard let wallpaper = try ArcKitRecord.load(WallpaperCatalog.self, layout: WallpaperCatalog.recordLayout, db: db),
                  let background = try ArcKitRecord.load(AppBackgroundSettings.self, layout: AppBackgroundSettings.recordLayout, db: db),
                  try ArcKitRecord.load(WallpaperSourceConfiguration.self, layout: WallpaperSourceConfiguration.recordLayout, db: db) != nil else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupLacksFeatureRecords)) }
            _ = try wallpaper.validated(); _ = try background.validated()
            let entries = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
            var assets: [String: StorageBackupManifest.File] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path,digest,byte_count FROM assets") {
                // 外部备份不能信任声明的列类型；拒绝坏记录，避免强制转换终止进程。
                guard case .string(let path) = (row["path"] as DatabaseValue).storage,
                      case .string(let digest) = (row["digest"] as DatabaseValue).storage,
                      case .int64(let bytes) = (row["byte_count"] as DatabaseValue).storage,
                      bytes >= 0 else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageInvalidAssetIndexFieldTypesBackup)) }
                guard let entry = entries[path], !entry.isDirectory, entry.digest == digest, entry.bytes == bytes else {
                    throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageDatabaseAssetReferenceMissing(String(describing: path))))
                }
                assets[digest] = entry
            }
            // 哈希外键只证明资产存在；还要验证业务实际打开的文件名与大小，避免恢复出无法读取的图库。
            for item in wallpaper.items {
                let path = "assets/media/" + item.filename
                guard let asset = assets[item.digest], asset.path == path, asset.bytes == item.byteCount else {
                    throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageDatabaseAssetReferenceMissing(String(describing: path))))
                }
            }
            if let id = background.imageID {
                guard let asset = assets[id], asset.path.hasPrefix("assets/media/" + id + "."),
                      !asset.path.dropFirst("assets/media/".count).contains("/") else {
                    throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageDatabaseAssetReferenceMissing(String(describing: id))))
                }
            }
            for template in settings.finder.menuConfiguration.fileTemplates {
                if case .managedUserFile(let path) = template.templateSource {
                    guard entries[try templateRelativePath(path)] != nil else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupLacksCustomTemplates)) }
                }
            }
            if let filename = background.videoFilename {
                let digest = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                // 清单中碰巧存在同名文件，不等于它是内容寻址的背景视频资产。
                guard assets[digest]?.path == "assets/media/" + filename else {
                    throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackupLacksBackgroundVideo))
                }
            }
        }
    }
    private struct FileInfo { let url: URL; let bytes: Int64; let modified: Date; let isDirectory: Bool }
    private func files(under root: URL) throws -> [FileInfo] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func inspect(_ url: URL) throws -> FileInfo? {
            let v = try url.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true else { throw StoragePathError.unsafeRoot }
            return v.isRegularFile == true || v.isDirectory == true ? FileInfo(url: url, bytes: v.isDirectory == true ? 0 : Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast, isDirectory: v.isDirectory == true) : nil
        }
        if let single = try inspect(root), !single.isDirectory { return [single] }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        return try enumerator.compactMap { try ($0 as? URL).flatMap(inspect) }
    }
    private func retain(in directory: URL, count: Int, days: Int?, prefix: String = "") throws {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (index, url) in urls.enumerated() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if index >= count || days.map({ Date().timeIntervalSince(modified) > Double($0 * 86400) }) == true { try FileManager.default.removeItem(at: url) }
        }
    }
}

/// 启动前的离线恢复入口，即使原库无法打开也能恢复，不会启动 GUI 或后台。
public enum StorageRecovery {
    public static func run(source: URL, destination: URL) throws {
        let paths = ArcKitStoragePaths(root: destination)
        if let owner = try? RuntimeHostSession.load(from: paths.owner), owner.isOwnerAlive {
            throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageQuitArcKitUsingDirectory))
        }
        guard let host = ArcKitProcessLock.acquire(for: .host, lockPath: paths.lock(.host).path),
              let worker = ArcKitProcessLock.acquire(for: .worker, lockPath: paths.lock(.worker).path) else {
            throw ArcKitDatabaseError.message(L10n.string(.DataManagement.storageBackgroundTasksStillUseDataWait))
        }
        let database = ApplicationStorage.makeDatabase(paths: paths)
        defer { try? database.close(); withExtendedLifetime((host, worker)) {} }
        try StorageMaintenance(database: database).restore(source)
    }
}
