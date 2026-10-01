import Foundation

/// Shell 参数引用与目标目录解析。
public enum ShellQuoting {

    /// 对路径做单引号转义，防止特殊字符破坏 shell 命令。
    public static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// 对于文件返回其父目录，对于目录返回自身。
    public static func directoryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}
