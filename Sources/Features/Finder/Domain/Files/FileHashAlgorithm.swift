import ArcKitPlatform
import CryptoKit
import Foundation

/// 文件哈希算法。
public enum FileHashAlgorithm: String, CaseIterable, Codable, Sendable, Identifiable {
    case md5
    case sha1
    case sha256

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .md5:   "MD5"
        case .sha1:  "SHA1"
        case .sha256: "SHA256"
        }
    }

    /// 内存中计算哈希，供单元测试和后续复用。
    public func hexDigest(for data: Data) -> String {
        switch self {
        case .md5:
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha1:
            return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// 文件摘要按块更新哈希状态，文件大小不再等于 Finder Worker 的峰值内存。
    public func hexDigest(forFileAt url: URL, chunkBytes: Int = 1 * 1_024 * 1_024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = max(1, min(chunkBytes, 8 * 1_024 * 1_024))
        switch self {
        case .md5:
            var hasher = Insecure.MD5()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Self.hex(hasher.finalize())
        case .sha1:
            var hasher = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Self.hex(hasher.finalize())
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Self.hex(hasher.finalize())
        }
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
