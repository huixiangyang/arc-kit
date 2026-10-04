import ArcKitPlatform
import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let navigation = MainWindowNavigationModel()
    private let makeContent: (MainWindowNavigationModel) -> AnyView
    private let refreshFinder: () -> Void
    private let setWindowVisible: (Bool) -> Void
    private let windowTitle: String
    private var window: NSWindow?

    init<Content: View>(windowTitle: String = "Arc Kit", refreshFinder: @escaping () -> Void,
                       setWindowVisible: @escaping (Bool) -> Void,
                       @ViewBuilder content: @escaping (MainWindowNavigationModel) -> Content) {
        self.windowTitle = windowTitle
        self.refreshFinder = refreshFinder
        self.setWindowVisible = setWindowVisible
        self.makeContent = { AnyView(content($0)) }
        super.init()
    }

    func show(
        section: MainWindowSection? = nil,
        preferenceTarget: PreferencesWorkspaceTarget? = nil,
        windowTarget: WindowWorkspaceTab? = nil,
        opensQuickFind: Bool = false
    ) {
        if let section {
            navigation.selection = section
        }
        if let preferenceTarget {
            navigation.requestPreferences(preferenceTarget)
        }
        if let windowTarget { navigation.windowTarget = windowTarget }
        if opensQuickFind {
            navigation.requestQuickFind()
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = makeContent(navigation)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isRestorable = false
        window.minSize = NSSize(width: ArcMetrics.mainWindowMinWidth, height: ArcMetrics.mainWindowMinHeight)
        let visibleSize = NSScreen.main?.visibleFrame.size
        let availableWidth = visibleSize.map { max(ArcMetrics.mainWindowMinWidth, $0.width - 48) }
            ?? ArcMetrics.mainWindowDefaultWidth
        let availableHeight = visibleSize.map { max(ArcMetrics.mainWindowMinHeight, $0.height - 48) }
            ?? ArcMetrics.mainWindowDefaultHeight
        window.setContentSize(NSSize(
            width: min(ArcMetrics.mainWindowDefaultWidth, availableWidth),
            height: min(ArcMetrics.mainWindowDefaultHeight, availableHeight)
        ))
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        // 首次启动居中；之后由系统恢复用户调整后的窗口位置与尺寸。
        if !window.setFrameUsingName("ArcKitMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ArcKitMainWindow")
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func refreshFinderAfterRepair() {
        refreshFinder()
    }

    func windowWillClose(_ notification: Notification) {
        setWindowVisible(false)
        window?.contentViewController = nil
        window = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        setWindowVisible(window?.occlusionState.contains(.visible) == true)
    }

}
