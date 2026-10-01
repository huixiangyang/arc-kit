import ArcKitPlatform
import AppKit
import ArcKitFinder

/// 长报告使用非模态窗口；采集、滚动和窗口关闭互不阻塞。
@MainActor
final class FinderDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    private var reportView: NSTextView?
    private var copyButton: NSButton?
    private var reportTask: Task<Void, Never>?

    init() { super.init(window: nil) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(snapshotStore: FinderExtensionSnapshotStore, accessibilityStatus: String) {
        // 重复点击只唤起同一窗口，不叠加模态循环或诊断任务。
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        reportTask = Task { [weak self] in
            let health = await FinderExtensionStatusService.refreshHealth(snapshotStore: snapshotStore, reason: "diagnostics")
            guard !Task.isCancelled else { return }
            let report = await Task.detached(priority: .utility) {
                FinderDiagnosticsReport.capture(
                    snapshotStore: snapshotStore,
                    health: health,
                    accessibilityStatus: accessibilityStatus
                )
            }.value
            // 关闭后丢弃迟到结果；旧任务不能更新再次打开的新窗口。
            guard !Task.isCancelled, let self, self.window != nil else { return }
            reportView?.string = report
            reportView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            copyButton?.isEnabled = true
            reportTask = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: min(760, visibleFrame.width - 48), height: min(600, visibleFrame.height - 72))
        let window = FinderDiagnosticsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string(.FinderSettings.diagnosticsExportFinderTechnicalDetails)
        window.minSize = NSSize(width: min(480, size.width), height: min(320, size.height))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self

        let content = NSView()
        window.contentView = content
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = L10n.string(.FinderSettings.diagnosticsExportCollecting)
        textView.setAccessibilityLabel(L10n.string(.FinderSettings.diagnosticsExportFinderDiagnosticReport))
        reportView = textView

        let copyButton = NSButton(title: L10n.string(.FinderSettings.diagnosticsExportCopyReport), target: self, action: #selector(copyReport))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        self.copyButton = copyButton

        let closeButton = NSButton(title: L10n.string(.Common.close), target: self, action: #selector(closeReport))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        for view in [scrollView, separator, copyButton, closeButton] { content.addSubview(view) }

        // 按钮固定在滚动区外，报告长度不能将关闭入口挤出屏幕。
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            copyButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            copyButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            copyButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -16)
        ])
        window.center()
        return window
    }

    @objc private func copyReport() {
        guard let report = reportView?.string, copyButton?.isEnabled == true else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func closeReport() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        reportTask?.cancel()
        reportTask = nil
        reportView = nil
        copyButton = nil
        window = nil
    }
}

private final class FinderDiagnosticsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
