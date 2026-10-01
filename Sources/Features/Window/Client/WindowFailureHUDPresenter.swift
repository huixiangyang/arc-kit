import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
@preconcurrency import AppKit
import Foundation

/// 窗口管理的失败提示必须明确可见，但不能像 modal alert 一样打断快捷键/拖拽工作流。
@MainActor
final class WindowFailureHUDPresenter {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(message: String) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel(message: message)
        position(panel)
        self.panel = panel
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: workItem)
    }

    static func makePanel(message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 14, y: 24, width: 24, height: 24))
        icon.image = ArcIconImage.image(.triangleAlert)
        icon.contentTintColor = .systemOrange
        effect.addSubview(icon)

        let title = NSTextField(labelWithString: L10n.string(.App.searchWindowManagement))
        title.frame = NSRect(x: 48, y: 42, width: 248, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        effect.addSubview(title)

        let detail = NSTextField(labelWithString: message)
        detail.frame = NSRect(x: 48, y: 14, width: 254, height: 28)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.setAccessibilityIdentifier("ArcKitWindowFailureHUDMessage")
        effect.addSubview(detail)

        panel.contentView = effect
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let margin: CGFloat = 18
        let frame = NSRect(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(frame, display: false)
    }
}
