import ArcKitPlatform
import Foundation

public enum FinderScriptExecutionError: LocalizedError, Equatable {
    case invalidAbsolutePath(String)
    case missingScript(String)
    case directoryInsteadOfScript(String)
    case symbolicLinkNotAllowed(String)
    case nonRegularFile(String)
    case unreadableScript(String)
    case scriptTooLarge(String)
    case unsupportedExtension(String)
    case interpreterUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAbsolutePath(path):
            L10n.string(.Finder.scriptValidationScriptPathNormalizedAbsolute(String(describing: path)))
        case let .missingScript(path):
            L10n.string(.Finder.scriptValidationScriptFileMissing(String(describing: path)))
        case let .directoryInsteadOfScript(path):
            L10n.string(.Finder.scriptValidationSelectedFolderInsteadScript(String(describing: path)))
        case let .symbolicLinkNotAllowed(path):
            L10n.string(.Finder.scriptValidationSymlinkRejected(String(describing: path)))
        case let .nonRegularFile(path):
            L10n.string(.Finder.scriptValidationRegularScriptFilesExecuted(String(describing: path)))
        case let .unreadableScript(path):
            L10n.string(.Finder.scriptValidationScriptUnreadable(String(describing: path)))
        case let .scriptTooLarge(path):
            L10n.string(.Finder.scriptValidationSizeLimit(String(describing: path)))
        case let .unsupportedExtension(ext):
            L10n.string(.Finder.scriptValidationUnsupportedType(String(describing: ext)))
        case let .interpreterUnavailable(name):
            L10n.string(.Finder.scriptValidationAvailableScriptInterpreterMissing(String(describing: name)))
        }
    }
}

/// 扩展入队和后台执行共用的脚本准入规则，不构造或启动执行命令。
public enum FinderScriptValidation {
    private static let supportedScriptExtensions = ["sh", "py", "js"]

    /// 扩展侧只传脚本路径；这里拒绝相对路径、链接、特殊文件和超大文件。
    public static func validate(_ scriptPath: String, fileManager: FileManager = .default) throws -> String {
        guard !scriptPath.isEmpty, NSString(string: scriptPath).isAbsolutePath else {
            throw FinderScriptExecutionError.invalidAbsolutePath(scriptPath)
        }
        let path = URL(fileURLWithPath: scriptPath).standardizedFileURL.path
        guard path == scriptPath else {
            throw FinderScriptExecutionError.invalidAbsolutePath(scriptPath)
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FinderScriptExecutionError.missingScript(scriptPath)
        }
        guard !isDirectory.boolValue else {
            throw FinderScriptExecutionError.directoryInsteadOfScript(scriptPath)
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw FinderScriptExecutionError.nonRegularFile(path)
        }
        guard type != .typeSymbolicLink else {
            throw FinderScriptExecutionError.symbolicLinkNotAllowed(path)
        }
        guard type == .typeRegular else {
            throw FinderScriptExecutionError.nonRegularFile(path)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw FinderScriptExecutionError.unreadableScript(path)
        }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > 8 * 1024 * 1024 {
            throw FinderScriptExecutionError.scriptTooLarge(path)
        }

        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard Self.supportedScriptExtensions.contains(ext) else {
            throw FinderScriptExecutionError.unsupportedExtension(ext.isEmpty ? "-" : ext)
        }
        return path
    }
}
