import Foundation

/// 检查本次临时输出，不能把进程成功当作产物成功。
struct FinderGeneratedOutputVerifier {
    let fileManager: FileManager

    func verifyNonEmptyFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FinderCommandExecutionError.outputVerificationFailed(url.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw FinderCommandExecutionError.outputVerificationFailed(url.path)
        }
    }
}
