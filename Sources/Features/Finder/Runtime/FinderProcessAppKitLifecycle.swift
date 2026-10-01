import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit

/// Finder Agent 与一次性 Worker 各自在需要窗口时调用；每个进程只初始化一次 AppKit 生命周期。
@MainActor
enum FinderProcessAppKitLifecycle {
    private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            false
        }
    }

    private static var didBootstrap = false
    private static let applicationDelegate = ApplicationDelegate()

    @discardableResult
    static func ensureReady(activate: Bool = false) -> NSApplication {
        let application = NSApplication.shared
        if !didBootstrap {
            application.delegate = applicationDelegate
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            didBootstrap = true
        }
        if activate {
            application.activate(ignoringOtherApps: true)
        }
        return application
    }
}
