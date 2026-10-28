import ArcKitPersistence
import ArcKitPlatform
import Foundation

/// 索引在应用单库，原始快照为不可变资产；SQL 失败不发布半份版本。
struct AgentSessionStore: Sendable {
    let database: ArcKitDatabase

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE agent_session_versions (
                id TEXT PRIMARY KEY, source_id TEXT NOT NULL, session_id TEXT NOT NULL,
                captured_at REAL NOT NULL, metadata TEXT NOT NULL, source_name TEXT NOT NULL,
                digest TEXT NOT NULL REFERENCES assets(digest), complete INTEGER NOT NULL CHECK(complete IN (0,1)),
                retained INTEGER NOT NULL DEFAULT 0 CHECK(retained IN (0,1))
            );
            CREATE INDEX agent_session_version_history ON agent_session_versions(source_id,session_id,captured_at DESC);
            CREATE TABLE agent_session_jobs (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL,
                result TEXT NOT NULL, detail TEXT NOT NULL
            );
            """)
    }
    func versions() throws -> [AgentSessionVersion] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT v.*,a.path,a.byte_count FROM agent_session_versions v JOIN assets a ON a.digest=v.digest ORDER BY v.captured_at DESC,v.id").map(Self.version)
        }
    }
    static func version(_ row: Row) throws -> AgentSessionVersion {
        guard let rawID = String.fromDatabaseValue(row["id"]), let id = UUID(uuidString: rawID),
              let rawSource = String.fromDatabaseValue(row["source_id"]), let source = UUID(uuidString: rawSource),
              let session = String.fromDatabaseValue(row["session_id"]),
              let date = Double.fromDatabaseValue(row["captured_at"]), date.isFinite,
              let metadata = String.fromDatabaseValue(row["metadata"]),
              let path = String.fromDatabaseValue(row["path"]), let count = Int64.fromDatabaseValue(row["byte_count"]),
              let complete = Bool.fromDatabaseValue(row["complete"]), let retained = Bool.fromDatabaseValue(row["retained"]) else { throw AgentSessionError.invalidArchive }
        return AgentSessionVersion(id: id, key: .init(sourceID: source, sessionID: session), capturedAt: Date(timeIntervalSinceReferenceDate: date),
            metadata: try JSONDecoder().decode(AgentSessionMetadata.self, from: Data(metadata.utf8)), relativePath: path, byteCount: count, complete: complete, retained: retained)
    }
    func payload(_ version: AgentSessionVersion, verifyIntegrity: Bool = false) throws -> AgentSessionPayload {
        guard version.relativePath.hasPrefix("assets/agent-sessions/"), version.byteCount > 0, version.byteCount <= AgentSessionArchive.maximumBytes else { throw AgentSessionError.invalidArchive }
        let file = try CodexSessionAdapter.safeURL(version.relativePath, under: database.paths.root)
        if verifyIntegrity {
            guard try ArcKitAssetStore.digest(file) == file.deletingPathExtension().lastPathComponent else { throw AgentSessionError.invalidArchive }
        }
        let data = try CodexSessionAdapter.read(file, limit: AgentSessionArchive.maximumBytes)
        guard data.count == version.byteCount else { throw AgentSessionError.invalidArchive }
        var payload = try PropertyListDecoder().decode(AgentSessionPayload.self, from: data).validated()
        guard payload.key == version.key, payload.metadata == version.metadata, payload.isComplete == version.complete else { throw AgentSessionError.invalidArchive }
        payload.capturedAt = version.capturedAt
        return payload
    }
    func archivedRows() throws -> [AgentSessionRow] {
        let versions = try versions()
        var seen = Set<AgentSessionKey>()
        return try versions.filter { seen.insert($0.key).inserted }.map { version in
            let name = try database.read { try String.fetchOne($0, sql: "SELECT source_name FROM agent_session_versions WHERE id=?", arguments: [version.id.uuidString]) } ?? "Codex"
            return .init(key: version.key, metadata: version.metadata, sourceName: name, latest: version, sourceMissing: false)
        }
    }
    @discardableResult func save(_ payload: AgentSessionPayload, capacityBytes: Int64, forceCheckpoint: Bool = false) throws -> AgentSessionVersion {
        try saveBatch([payload], capacityBytes: capacityBytes, forceCheckpoints: forceCheckpoint ? [payload.key] : [])[0]
    }
    @discardableResult func saveBatch(_ payloads: [AgentSessionPayload], capacityBytes: Int64, forceCheckpoints: Set<AgentSessionKey> = []) throws -> [AgentSessionVersion] {
        let previous = try versions()
        var result: [AgentSessionVersion] = []
        var pending: [(AgentSessionPayload, AgentSessionVersion, String)] = []
        var newFiles: [URL] = []
        var used = try byteCount()
        let folder = try database.paths.makeTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        var committed = false
        defer {
            if !committed { for file in newFiles { try? FileManager.default.removeItem(at: file) } }
        }
        for payload in payloads {
            _ = try payload.validated()
            if let oldVersion = previous.first(where: { $0.key == payload.key }) {
                var old = try self.payload(oldVersion); old.capturedAt = payload.capturedAt
                if old == payload {
                    if forceCheckpoints.contains(payload.key) {
                        let checkpoint = AgentSessionVersion(id: UUID(), key: oldVersion.key, capturedAt: payload.capturedAt,
                            metadata: oldVersion.metadata, relativePath: oldVersion.relativePath, byteCount: oldVersion.byteCount,
                            complete: oldVersion.complete, retained: false)
                        pending.append((payload, checkpoint, URL(fileURLWithPath: oldVersion.relativePath).deletingPathExtension().lastPathComponent))
                        result.append(checkpoint)
                    } else { result.append(oldVersion) }
                    continue
                }
            }
            let data = try payload.encoded()
            used += Int64(data.count)
            guard data.count <= AgentSessionArchive.maximumBytes, used <= capacityBytes else { throw AgentSessionError.capacity }
            let temporary = folder.appendingPathComponent(UUID().uuidString + ".session")
            try ArcKitAtomicFile.writeAtomically(data, to: temporary)
            // 摘要用于备份完整性和不可变版本去重，不在普通扫描中全量计算。
            let digest = try ArcKitAssetStore.digest(temporary)
            let relative = "assets/agent-sessions/\(digest).session"
            let target = try CodexSessionAdapter.safeURL(relative, under: database.paths.root)
            try ArcKitStoragePaths.secureDirectory(target.deletingLastPathComponent())
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: temporary, to: target); newFiles.append(target)
            }
            try ArcKitStoragePaths.synchronizeDirectory(target.deletingLastPathComponent())
            let version = AgentSessionVersion(id: UUID(), key: payload.key, capturedAt: payload.capturedAt, metadata: payload.metadata,
                relativePath: relative, byteCount: Int64(data.count), complete: payload.isComplete, retained: false)
            pending.append((payload, version, digest)); result.append(version)
        }
        // 批量导入以一次 SQL 事务发布；任何条目失败都不会出现半个导入集合。
        try database.write { db in
            for (payload, version, digest) in pending {
                try db.execute(sql: "INSERT INTO assets(digest,path,byte_count) VALUES (?,?,?) ON CONFLICT(digest) DO NOTHING", arguments: [digest, version.relativePath, version.byteCount])
                let metadata = String(decoding: try JSONEncoder().encode(payload.metadata), as: UTF8.self)
                try db.execute(sql: "INSERT INTO agent_session_versions(id,source_id,session_id,captured_at,metadata,source_name,digest,complete,retained) VALUES (?,?,?,?,?,?,?,?,0)",
                    arguments: [version.id.uuidString, payload.sourceID.uuidString, payload.metadata.sessionID, payload.capturedAt.timeIntervalSinceReferenceDate, metadata, payload.sourceName, digest, payload.isComplete])
                try Self.indexSearch(payload, digest: digest, db: db)
            }
            if !pending.isEmpty { try ArcKitDatabase.advance(db) }
        }
        committed = true
        return result
    }
    func byteCount() throws -> Int64 {
        try database.read { try Int64.fetchOne($0, sql: "SELECT coalesce(sum(byte_count),0) FROM assets WHERE path LIKE 'assets/agent-sessions/%'") ?? 0 }
    }
    func retain(_ version: AgentSessionVersion, value: Bool) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE agent_session_versions SET retained=? WHERE id=?", arguments: [value, version.id.uuidString]); try ArcKitDatabase.advance(db)
        }
    }
    func prune(days: Int, now: Date = Date()) throws {
        let versions = try versions()
        var latest = Set<AgentSessionKey>(); var complete = Set<AgentSessionKey>()
        var required = versions.filter { version in
            let newest = latest.insert(version.key).inserted
            let lastComplete = version.complete && complete.insert(version.key).inserted
            return newest || lastComplete || version.retained || now.timeIntervalSince(version.capturedAt) <= Double(days) * 86400
        }
        var protectedVersions = Set<UUID>()
        // 保留版本的父子会话形成引用闭包；固定父版本不能因子版本轮换而失去恢复能力。
        while let version = required.popLast() {
            guard protectedVersions.insert(version.id).inserted else { continue }
            for id in version.metadata.childIDs + [version.metadata.parentID].compactMap({ $0 }) {
                if let related = versions.first(where: { $0.key.sourceID == version.key.sourceID && $0.key.sessionID == id && $0.capturedAt <= version.capturedAt }) { required.append(related) }
            }
        }
        let expired = versions.filter { !protectedVersions.contains($0.id) }
        // 先删引用、后回收仅本功能的无引用资产。外部导出是自包含包，不依赖这些对象。
        try database.write { db in
            for version in expired { try db.execute(sql: "DELETE FROM agent_session_versions WHERE id=?", arguments: [version.id.uuidString]) }
            if !expired.isEmpty { try ArcKitDatabase.advance(db) }
        }
        let unused = try database.read { try Row.fetchAll($0, sql: "SELECT digest,path FROM assets WHERE path LIKE 'assets/agent-sessions/%' AND digest NOT IN (SELECT digest FROM agent_session_versions)") }
        // 应用的元数据恢复点仍依赖本地资产；只有自包含的导出包可以脱离原文件。
        var protected = Set<String>()
        for snapshot in try FileManager.default.contentsOfDirectory(at: database.paths.backups, includingPropertiesForKeys: nil)
            where snapshot.lastPathComponent.hasPrefix("snapshot-") && snapshot.pathExtension == "arckitbackup" {
            let data = try CodexSessionAdapter.read(snapshot.appendingPathComponent("manifest.json"), limit: 8 * 1_024 * 1_024)
            let manifest = try JSONDecoder().decode(StorageBackupManifest.self, from: data)
            if !manifest.includesAssets { protected.formUnion(manifest.files.filter { $0.path.hasPrefix("assets/agent-sessions/") }.map(\.digest)) }
        }
        for row in unused {
            guard let path = String.fromDatabaseValue(row["path"]), let digest = String.fromDatabaseValue(row["digest"]) else { throw AgentSessionError.invalidArchive }
            if protected.contains(digest) { continue }
            let url = try CodexSessionAdapter.safeURL(path, under: database.paths.root)
            // 文件删除失败保留索引，便于下次重试；此 store 由模型串行调用。
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try database.write { try $0.execute(sql: "DELETE FROM assets WHERE digest=? AND digest NOT IN (SELECT digest FROM agent_session_versions)", arguments: [digest]) }
        }
    }
    func beginJob(_ kind: String) throws -> UUID {
        let id = UUID()
        try database.write { try $0.execute(sql: "INSERT INTO agent_session_jobs VALUES (?,?,?,NULL,'running','')", arguments: [id.uuidString, kind, Date().timeIntervalSince1970]) }
        return id
    }
    func finishJob(_ id: UUID, result: String, detail: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE agent_session_jobs SET finished_at=?,result=?,detail=? WHERE id=?", arguments: [Date().timeIntervalSince1970, result, detail, id.uuidString])
            try db.execute(sql: "DELETE FROM agent_session_jobs WHERE result!='running' AND id NOT IN (SELECT id FROM agent_session_jobs ORDER BY started_at DESC LIMIT 100)")
        }
    }
    func recoverJobs() throws {
        try database.write { try $0.execute(sql: "UPDATE agent_session_jobs SET result='interrupted',finished_at=? WHERE result='running'", arguments: [Date().timeIntervalSince1970]) }
    }
    /// 完整应用备份还要核对会话版本与资产的真实引用，不只检查文件存在。
    static func validateReferences(_ db: Database, entries: [String: StorageBackupManifest.File]) throws {
        for row in try Row.fetchAll(db, sql: "SELECT v.*,a.path,a.byte_count FROM agent_session_versions v JOIN assets a ON a.digest=v.digest") {
            let v = try version(row)
            guard v.relativePath.hasPrefix("assets/agent-sessions/"), let file = entries[v.relativePath], !file.isDirectory, file.bytes == v.byteCount, UUID(uuidString: v.metadata.sessionID) != nil, v.metadata.sessionID == v.key.sessionID else { throw AgentSessionError.invalidArchive }
        }
    }
}
