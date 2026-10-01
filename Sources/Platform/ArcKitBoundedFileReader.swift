import Foundation

public enum ArcKitBoundedFileReaderError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(fileName: String, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .fileTooLarge(fileName, maximumBytes):
            L10n.string(.Platform.fileFileExceeds(String(describing: ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)))) +
                L10n.string(.Platform.fileLimit(String(describing: fileName)))
        }
    }
}

/// 对可被其他进程或损坏状态替换的文件执行有界读取，长度判断和实际读取使用同一文件描述符。
public enum ArcKitBoundedFileReader {
    public static func read(
        from url: URL,
        maximumBytes: Int,
        chunkBytes: Int = 64 * 1_024
    ) throws -> Data {
        let resolvedMaximum = max(1, maximumBytes)
        let resolvedChunk = max(1, min(chunkBytes, resolvedMaximum))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: resolvedChunk), !chunk.isEmpty {
            guard chunk.count <= resolvedMaximum - data.count else {
                throw ArcKitBoundedFileReaderError.fileTooLarge(
                    fileName: url.lastPathComponent,
                    maximumBytes: resolvedMaximum
                )
            }
            data.append(chunk)
        }
        return data
    }
}
