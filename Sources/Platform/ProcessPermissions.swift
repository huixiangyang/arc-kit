import ApplicationServices
import Foundation

/// 权限属于执行进程。查询不缓存、不弹窗；AX 由 Host 申请，菜单栏只读输入由主 App 申请。
public enum ProcessPermissions {
    public static func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    @MainActor
    public static func requestAccessibility() {
        guard !accessibilityTrusted() else { return }
        // 使用稳定 key，避免 Swift 6 对 SDK 全局变量的并发安全诊断。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func canListenToInput() -> Bool { CGPreflightListenEventAccess() }

    @MainActor
    public static func requestInputListening() {
        guard !canListenToInput() else { return }
        _ = CGRequestListenEventAccess()
    }

    public static func snapshot() -> RuntimePermissionSnapshot {
        .init(processID: ProcessInfo.processInfo.processIdentifier,
              accessibilityTrusted: accessibilityTrusted(), checkedAt: Date())
    }
}

/// 仅由已验证的 Host 控制连接传输，不持久化成用户配置，也不从主 App 的 TCC 状态推测。
public struct RuntimePermissionSnapshot: Codable, Equatable, Sendable {
    public let processID: Int32
    public let accessibilityTrusted: Bool
    public let checkedAt: Date

    public init(processID: Int32, accessibilityTrusted: Bool, checkedAt: Date) {
        self.processID = processID
        self.accessibilityTrusted = accessibilityTrusted
        self.checkedAt = checkedAt
    }

    public func isCurrent(at now: Date = Date()) -> Bool {
        processID > 0 && (0...30).contains(now.timeIntervalSince(checkedAt))
    }
}
