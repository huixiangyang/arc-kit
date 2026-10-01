@preconcurrency import AppKit
import Foundation

/// 设置按事件目标 PID 匹配，滚动非前台窗口也使用该应用配置。输入热路径不查询 NSWorkspace。
final class MouseApplicationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var bundles: [pid_t: String] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        for application in NSWorkspace.shared.runningApplications { update(application, removing: false) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.update(app, removing: notification.name == NSWorkspace.didTerminateApplicationNotification)
            })
        }
    }

    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func bundleIdentifier(for pid: pid_t) -> String? { lock.withLock { bundles[pid] } }
    private func update(_ app: NSRunningApplication, removing: Bool) {
        lock.withLock { bundles[app.processIdentifier] = removing ? nil : app.bundleIdentifier }
    }
}
