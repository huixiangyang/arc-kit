import Darwin
import Foundation

/// Arc Kit 的原子写入工具。
///
/// 正式 Finder 右键链路不再读写 App Group 文件，避免 macOS 把
/// `~/Library/Group Containers` 访问识别为“访问其他 App 数据”。本类型只负责
/// 明确传入路径的原子写入，供运行诊断和接收凭证等调用方使用。
public enum ArcKitAtomicFile {

    public static func writeAtomically(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try ArcKitStoragePaths.secureDirectory(directory)
        } else {
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw StoragePathError.unsafeRoot }
        }
        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // 替换、移动或磁盘异常失败时也必须清理临时文件，避免长期运行后堆积残片。
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try data.write(to: temporaryURL, options: [.atomic])
        try ArcKitStoragePaths.secureFile(temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize(); try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
