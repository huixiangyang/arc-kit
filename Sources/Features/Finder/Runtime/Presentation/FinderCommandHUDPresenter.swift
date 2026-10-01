import ArcKitPlatform
import ArcKitFinder
@preconcurrency import AppKit
import Foundation

enum FinderCommandHUDStyle {
    case success
    case failure

    var icon: ArcIconName {
        switch self {
        case .success: .checkCircle
        case .failure: .triangleAlert
        }
    }

    var tintColor: NSColor {
        switch self {
        case .success: .systemGreen
        case .failure: .systemOrange
        }
    }

    var displayDuration: TimeInterval {
        switch self {
        case .success: 2.2
        case .failure: 3.2
        }
    }
}

/// Finder Agent 的统一结果回执不激活任何 App；只给不可见成功和真实失败提供短暂反馈。
@MainActor
final class FinderCommandHUDPresenter {
    static let shared = FinderCommandHUDPresenter()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var batchRenameUndoOffer: FinderBatchRenameUndoOffer?

    func show(style: FinderCommandHUDStyle, title: String, message: String) {
        ensureApplicationReadyForHUD()
        hideWorkItem?.cancel()
        batchRenameUndoOffer?.invalidate()
        batchRenameUndoOffer = nil
        panel?.orderOut(nil)

        let panel = Self.makePanel(style: style, title: title, message: message)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + style.displayDuration, execute: workItem)
    }

    func showBatchRenameUndo(_ offer: FinderBatchRenameUndoOffer) {
        ensureApplicationReadyForHUD()
        hideWorkItem?.cancel()
        batchRenameUndoOffer?.invalidate()
        panel?.orderOut(nil)

        let panel = Self.makeBatchRenameUndoPanel(itemCount: offer.itemCount)
        guard let button = Self.findSubview(
            in: panel.contentView,
            accessibilityIdentifier: "ArcKitFinderBatchRenameUndoButton"
        ) as? NSButton else {
            offer.invalidate()
            show(style: .failure, title: L10n.string(.FinderActions.feedbackUndoUnavailable), message: L10n.string(.FinderActions.feedbackUndoControlFailed))
            return
        }
        button.target = self
        button.action = #selector(performBatchRenameUndo)

        position(panel)
        self.panel = panel
        batchRenameUndoOffer = offer
        panel.orderFrontRegardless()

        let remainingDuration = max(0, offer.expiresAt.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self, weak offer] in
            Task { @MainActor in
                offer?.invalidate()
                self?.panel?.orderOut(nil)
                self?.panel = nil
                self?.batchRenameUndoOffer = nil
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDuration, execute: workItem)
    }

    static func makePanel(style: FinderCommandHUDStyle, title: String, message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 88),
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
        panel.setAccessibilityLabel("\(title)。\(message)")

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 16, y: 32, width: 24, height: 24))
        icon.image = ArcIconImage.image(style.icon)
        icon.contentTintColor = style.tintColor
        icon.setAccessibilityIdentifier("ArcKitFinderCommandHUDIcon")
        effect.addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 52, y: 54, width: 286, height: 18)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier("ArcKitFinderCommandHUDTitle")
        effect.addSubview(titleField)

        let detail = NSTextField(labelWithString: message)
        detail.frame = NSRect(x: 52, y: 16, width: 292, height: 36)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.setAccessibilityIdentifier("ArcKitFinderCommandHUDMessage")
        effect.addSubview(detail)

        panel.contentView = effect
        return panel
    }

    static func makeBatchRenameUndoPanel(itemCount: Int) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.setAccessibilityLabel(L10n.string(.FinderActions.feedbackRenamedItemsUndoNow(String(describing: itemCount))))

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 16, y: 32, width: 24, height: 24))
        icon.image = ArcIconImage.image(.checkCircle)
        icon.contentTintColor = .systemGreen
        icon.setAccessibilityIdentifier("ArcKitFinderBatchRenameUndoIcon")
        effect.addSubview(icon)

        let titleField = NSTextField(labelWithString: L10n.string(.FinderActions.renameCompletedCount(Int(itemCount))))
        titleField.frame = NSRect(x: 52, y: 54, width: 262, height: 18)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier("ArcKitFinderBatchRenameUndoTitle")
        effect.addSubview(titleField)

        let detail = NSTextField(labelWithString: L10n.string(.FinderActions.feedbackUndoNowRestoreOriginalNames))
        detail.frame = NSRect(x: 52, y: 18, width: 276, height: 32)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.setAccessibilityIdentifier("ArcKitFinderBatchRenameUndoMessage")
        effect.addSubview(detail)

        let undoButton = NSButton(title: L10n.string(.Common.undo), target: nil, action: nil)
        undoButton.frame = NSRect(x: 338, y: 27, width: 66, height: 34)
        undoButton.bezelStyle = .rounded
        undoButton.controlSize = .regular
        undoButton.font = .systemFont(ofSize: 12, weight: .semibold)
        undoButton.setAccessibilityIdentifier("ArcKitFinderBatchRenameUndoButton")
        effect.addSubview(undoButton)

        panel.contentView = effect
        return panel
    }

    @objc private func performBatchRenameUndo() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
        panel = nil
        let offer = batchRenameUndoOffer
        batchRenameUndoOffer = nil
        guard offer?.perform() == true else {
            show(style: .failure, title: L10n.string(.FinderActions.feedbackUndoExpired), message: L10n.string(.FinderActions.feedbackRunBatchRenameAgainUndoImmediately))
            return
        }
    }

    private func ensureApplicationReadyForHUD() {
        FinderProcessAppKitLifecycle.ensureReady()
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

    private static func findSubview(in view: NSView?, accessibilityIdentifier: String) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == accessibilityIdentifier { return view }
        for subview in view.subviews {
            if let match = findSubview(in: subview, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }
}
