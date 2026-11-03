#if DEBUG
import AppKit
import ArcKitPlatform
import Darwin

/// 用真实组合入口与真实原生菜单做短时验收；不读取生产设置或执行窗口/图标操作。
@MainActor
final class MenuBarCombinedEntryCheck: NSObject, NSWindowDelegate {
    private let directory: URL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "左侧切换 0 次 · 原生菜单打开 0 次")
    private var controller: MenuBarController!
    private var preview: MenuBarCombinedEntry!
    private var toggles = 0, menus = 0
    private var closed = false
    private var timer: Timer?

    init(directory: URL) throws {
        self.directory = directory
        super.init()
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let actions = MenuBarPanelActions(performWindow: { _, _ in }, performScene: { _ in }, undoScene: { _ in }, openScenes: {},
            setWindowEnabled: { _ in }, setMouseEnabled: { _ in }, setFinderEnabled: { _ in }, openSection: { _ in },
            retrySave: {}, checkState: {}, quit: { [weak self] in self?.finish() })
        controller = MenuBarController(actions: actions, collapse: { [weak self] in self?.setCollapsed(true) },
            reveal: { [weak self] in self?.setCollapsed(false) }, cleansRetiredPosition: false, prepare: { _, done in
                done(.unavailable("原生控件验收不执行窗口操作"))
            })
        controller.nativeCheckMenuDidOpen = { [weak self] in
            guard let self else { return }; menus += 1; record("native-menu-open")
        }
        controller.state.settings.windowManagement.isEnabled = false
        controller.state.settings.menuBar.isEnabled = true
        controller.state.collectionReady = true
        controller.refreshPresentation(isVisible: true)
        window.title = "Arc Kit 单入口验证"
        window.isReleasedWhenClosed = false; window.delegate = self
        let heading = NSTextField(labelWithString: "同一按钮：左侧切换，右侧打开原生面板")
        heading.frame = NSRect(x: 24, y: 166, width: 480, height: 24)
        let button = NSButton(frame: NSRect(x: 24, y: 104, width: 82, height: 34))
        button.isBordered = true
        preview = MenuBarCombinedEntry(button: button, collapse: { [weak self] in self?.setCollapsed(true) },
            reveal: { [weak self] in self?.setCollapsed(false) }, openMenu: { [weak self] in self?.controller.showNativeMenu() })
        preview.update(collectionVisible: true, presentation: .all, ready: true, busy: false, menuStatus: "Arc Kit")
        let open = NSButton(title: "打开原生面板", target: self, action: #selector(openPanel))
        open.frame = NSRect(x: 142, y: 104, width: 170, height: 34)
        label.frame = NSRect(x: 24, y: 48, width: 480, height: 24)
        for view in [heading, button, open, label] { window.contentView?.addSubview(view) }
        window.center(); window.makeKeyAndOrderFront(nil)
        timer = Timer(timeInterval: 180, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.finish() } }
        RunLoop.main.add(timer!, forMode: .common)
        record("ready")
    }

    private func setCollapsed(_ value: Bool) {
        toggles += 1
        controller.state.collectionPresentation = value ? .collapsed : .all
        controller.refreshPresentation(isVisible: true)
        preview?.update(collectionVisible: true, presentation: value ? .collapsed : .all, ready: true, busy: false, menuStatus: "Arc Kit")
        record("collection")
    }
    @objc private func openPanel() { controller.showNativeMenu() }
    private func record(_ stage: String) {
        label.stringValue = "左侧切换 \(toggles) 次 · 原生菜单打开 \(menus) 次"
        let report: [String: Any] = ["stage": stage, "toggles": toggles, "nativeMenuOpens": menus, "pid": getpid()]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
    }
    func windowWillClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !closed else { return }; closed = true
        controller.stop(); controller.refreshPresentation(isVisible: false)
        record("removed"); Darwin.exit(0)
    }
}
#endif
