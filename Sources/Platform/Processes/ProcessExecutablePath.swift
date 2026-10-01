import Darwin
import Foundation

/// 从内核读取实际执行文件。SMAppService 的 argv[0] 可以是相对 BundleProgram，不能用来验证安装路径。
public enum ProcessExecutablePath {
    public static func read(processID: Int32) -> String? {
        guard processID > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE 的 C 表达式宏无法导入 Swift，按系统头文件使用 4 * MAXPATHLEN。
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
