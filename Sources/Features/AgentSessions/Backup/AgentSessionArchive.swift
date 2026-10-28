import AppleArchive
import System
import ArcKitPlatform
import Foundation

/// 标准 Apple Encrypted Archive：系统 scrypt 派生口令密钥，AES-CTR + HMAC 认证；不自制密码协议。
enum AgentSessionArchive {
    static let maximumBytes = 512 * 1_024 * 1_024
    private struct Document: Codable { var format = 1; let sessions: [AgentSessionPayload] }

    static func export(_ payloads: [AgentSessionPayload], password: String, to url: URL) throws {
        guard password.count >= 12 else { throw AgentSessionError.passwordShort }
        guard !payloads.isEmpty else { throw AgentSessionError.invalidArchive }
        for payload in payloads { _ = try payload.validated() }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(Document(sessions: payloads))
        guard data.count <= maximumBytes else { throw AgentSessionError.capacity }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).aea")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(temporary.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerRead, .ownerWrite]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? file.close() }
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        try context.setPassword(password)
        guard let encrypted = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context) else { throw AgentSessionError.password }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = try encrypted.write(from: UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }; offset += count
                }
            }
            try encrypted.close(); try file.close()
        } catch { encrypted.cancel(); throw error }
        // 完整解密回读，只有口令和认证都有效的容器才能对外发布。
        guard try load(from: temporary, password: password) == payloads else { throw AgentSessionError.invalidArchive }
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: temporary, to: url)
        try ArcKitStoragePaths.synchronizeDirectory(url.deletingLastPathComponent())
    }
    static func load(from url: URL, password: String) throws -> [AgentSessionPayload] {
        try ArcKitStoragePaths.validateFile(url)
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumBytes else { throw AgentSessionError.invalidArchive }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [], permissions: []) else { throw CocoaError(.fileReadUnknown) }
        defer { try? file.close() }
        guard let context = ArchiveEncryptionContext(from: file), context.profile == .hkdf_sha256_aesctr_hmac__scrypt__none else { throw AgentSessionError.invalidArchive }
        try context.setPassword(password)
        guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context) else { throw AgentSessionError.password }
        defer { try? decrypted.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 1_048_576)
        do {
            while true {
                try Task.checkCancellation()
                let count = try buffer.withUnsafeMutableBytes { try decrypted.read(into: $0) }
                if count == 0 { break }
                guard result.count + count <= maximumBytes else { throw AgentSessionError.capacity }
                result.append(contentsOf: buffer.prefix(count))
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw AgentSessionError.password }
        let document = try PropertyListDecoder().decode(Document.self, from: result)
        guard document.format == 1, !document.sessions.isEmpty, document.sessions.count <= 10_000 else { throw AgentSessionError.invalidArchive }
        return try document.sessions.map { try $0.validated() }
    }
}
