import Darwin
import Foundation

/// 为 Arc Kit 启动的子进程构造最小环境，避免把登录会话中的令牌和凭据继续传播给 Worker 或脚本。
public enum ArcKitSubprocessEnvironment {
    private static let preservedKeys: Set<String> = [
        "HOME",
        "TMPDIR",
        "USER",
        "LOGNAME",
        "LANG",
        "SHELL",
        "__CF_USER_TEXT_ENCODING"
    ]

    public static func sanitized(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var result = environment.filter { key, _ in
            preservedKeys.contains(key) || key.hasPrefix("LC_")
        }
        // 系统目录保持最高优先级；仅追加固定的常见解释器目录，不接受父进程任意改写 PATH。
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    /// 常驻辅助进程不需要开发凭据；尽早从自身 C 环境中移除，缩短被进程检查工具读取的暴露窗口。
    public static func scrubSensitiveVariablesFromCurrentProcess() {
        for key in ProcessInfo.processInfo.environment.keys where isSensitiveKey(key) {
            Darwin.unsetenv(key)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return [
            "TOKEN",
            "SECRET",
            "PASSWORD",
            "CREDENTIAL",
            "PRIVATE_KEY",
            "ACCESS_KEY",
            "API_KEY"
        ].contains { normalized.contains($0) }
    }
}
