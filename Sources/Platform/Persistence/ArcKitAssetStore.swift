import ArcKitPlatform
import CryptoKit
import Foundation

public struct StoredAsset: Sendable {
    public let digest: String
    public let filename: String
    public let byteCount: Int64
    public let url: URL
}

/// 文件先完成复制、哈希和落盘，再允许 SQL 引用。不可变资源不在取消时直接删除，避免删到并发复用者。
public final class ArcKitAssetStore: Sendable {
    public let database: ArcKitDatabase
    public init(database: ArcKitDatabase) { self.database = database }
    public func importFile(_ source: URL, maximumBytes: Int64 = 2_147_483_648) throws -> StoredAsset {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.assetInvalidAssetSizeFileType)) }
        let ext = source.pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 12, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.assetInvalidAssetExtension)) }
        let task = try database.paths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: task) }
        let staging = task.appendingPathComponent("import.\(ext)")
        try FileManager.default.copyItem(at: source, to: staging)
        let digest = try Self.digest(staging)
        try ArcKitStoragePaths.secureFile(staging)
        let existingPath = try database.read { try String.fetchOne($0, sql: "SELECT path FROM assets WHERE digest=?", arguments: [digest]) }
        let filename = existingPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "\(digest).\(ext)"
        guard filename.hasPrefix(digest + "."), existingPath == nil || existingPath == "assets/media/" + filename else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.assetAssetRecordContainsInvalidPath)) }
        let target = database.paths.media.appendingPathComponent(filename)
        // 大文件校验和同步不占用 SQL 写事务。无清理器会删除导入中的不可变资源。
        if FileManager.default.fileExists(atPath: target.path) {
            try ArcKitStoragePaths.secureFile(target)
            guard try Self.digest(target) == digest else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.assetExistingAssetVerificationReuseRefusedFailed)) }
        } else {
            try ArcKitStoragePaths.secureDirectory(database.paths.media)
            do { try FileManager.default.moveItem(at: staging, to: target) }
            catch {
                guard FileManager.default.fileExists(atPath: target.path), try Self.digest(target) == digest else { throw error }
            }
            let handle = try FileHandle(forWritingTo: target); try handle.synchronize(); try handle.close()
        }
        try ArcKitStoragePaths.synchronizeDirectory(database.paths.media)
        try database.write { db in
            try db.execute(sql: "INSERT INTO assets(digest,path,byte_count) VALUES (?,?,?) ON CONFLICT(digest) DO NOTHING", arguments: [digest, "assets/media/" + filename, size])
        }
        return StoredAsset(digest: digest, filename: filename, byteCount: Int64(size), url: target)
    }
    public func importData(_ data: Data, extension ext: String) throws -> StoredAsset {
        let task = try database.paths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: task) }
        let file = task.appendingPathComponent("import.\(ext)")
        try data.write(to: file, options: .atomic)
        return try importFile(file)
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
