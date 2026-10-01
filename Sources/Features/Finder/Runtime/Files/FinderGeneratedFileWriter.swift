import ArcKitPlatform
import Darwin
import Foundation

/// 先在独立临时目录生成并校验，再以不覆盖方式发布到用户目录。
struct FinderGeneratedFileWriter {
    let fileManager: FileManager

    func write(beside destination: URL, generate: (URL) throws -> Void) throws -> URL {
        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let output = staging.appendingPathComponent(destination.lastPathComponent)
        try generate(output)
        try FinderGeneratedOutputVerifier(fileManager: fileManager).verifyNonEmptyFile(output)
        let attributes = try fileManager.attributesOfItem(atPath: output.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw FinderCommandExecutionError.outputVerificationFailed(output.path)
        }

        let parent = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let name = index == 1 ? destination.lastPathComponent
                : (ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)")
            let candidate = parent.appendingPathComponent(name)
            if (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil { continue }
            // 同卷排他重命名，在内核提交点拒绝覆盖，不依赖“先检查再写”的时间窗口。
            if Darwin.renamex_np(output.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            if code == EEXIST { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.outputAvailableOutputNamesMissing(String(describing: destination.path))))
    }
}
