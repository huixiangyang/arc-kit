import ArcKitPlatform
import ArcKitMouse
@preconcurrency import AppKit
import Carbon.HIToolbox


enum MouseGestureActionExecutionResult: Equatable {
    case succeeded
    case failed(String)
}

@MainActor
protocol MouseGestureHintPresenting: AnyObject {
    func begin(at point: CGPoint, threshold: Double)
    func update(current point: CGPoint, decision: MouseGestureDecision, threshold: Double)
    func finish(at point: CGPoint, decision: MouseGestureDecision)
    func fail(at point: CGPoint, message: String)
    func hideSoon()
    func hideImmediately()
}

@MainActor
final class MouseGestureHintPresenter: MouseGestureHintPresenting {
    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func begin(at point: CGPoint, threshold: Double) {
        show(
            title: L10n.string(.MouseRuntime.gestureMouseGestures),
            subtitle: L10n.string(.MouseRuntime.gestureDragBeyondPxPerformAction(String(describing: Int(threshold)))),
            at: point,
            accent: .systemBlue
        )
    }

    func update(current point: CGPoint, decision: MouseGestureDecision, threshold: Double) {
        switch decision {
        case let .belowThreshold(distance):
            show(
                title: L10n.string(.MouseRuntime.gestureKeepDragging),
                subtitle: "\(Int(distance)) / \(Int(threshold)) px",
                at: point,
                accent: .systemBlue
            )
        case let .noAction(direction, distance):
            show(
                title: direction.displayName,
                subtitle: L10n.string(.MouseRuntime.gestureActionAssignedPxMissing(String(describing: Int(distance)))),
                at: point,
                accent: .systemOrange
            )
        case let .execute(result):
            show(
                title: result.direction.displayName,
                subtitle: result.action.displayName,
                at: point,
                accent: .systemGreen
            )
        case .disabled:
            hideSoon()
        }
    }

    func finish(at point: CGPoint, decision: MouseGestureDecision) {
        switch decision {
        case let .execute(result):
            show(
                title: L10n.string(.MouseRuntime.gestureRun(String(describing: result.action.displayName))),
                subtitle: result.direction.displayName,
                at: point,
                accent: .systemGreen
            )
        case .belowThreshold:
            show(title: L10n.string(.MouseRuntime.gestureNormalRightClick), subtitle: L10n.string(.MouseRuntime.gestureBelowThreshold), at: point, accent: .systemGray)
        case .noAction:
            show(title: L10n.string(.MouseRuntime.gestureNormalRightClick), subtitle: L10n.string(.MouseRuntime.gestureActionAssignedDirectionMissing), at: point, accent: .systemGray)
        case .disabled:
            break
        }
        hideSoon()
    }

    func fail(at point: CGPoint, message: String) {
        show(title: L10n.string(.MouseRuntime.gestureGestureFailed), subtitle: message, at: point, accent: .systemRed)
        hideSoon()
    }

    func hideSoon() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.hideImmediately() }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: item)
    }

    func hideImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
    }

    private func show(title: String, subtitle: String, at point: CGPoint, accent: NSColor) {
        hideWorkItem?.cancel()
        let panel = window ?? makeWindow()
        window = panel
        if let view = panel.contentView as? MouseGestureHintView {
            view.update(title: title, subtitle: subtitle, accent: accent)
        }
        let coordinateSpace = ArcKitScreenCoordinateSpace(screenFrames: NSScreen.screens.map(\.frame))
        let frame = coordinateSpace.accessibilityToAppKit(
            CGRect(x: point.x + 18, y: point.y + 18, width: 184, height: 58)
        )
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 184, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = MouseGestureHintView(frame: panel.contentRect(forFrameRect: panel.frame))
        return panel
    }
}

private final class MouseGestureHintView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let accentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        accentView.wantsLayer = true
        accentView.layer?.cornerRadius = 4
        addSubview(accentView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    override func layout() {
        super.layout()
        accentView.frame = CGRect(x: 12, y: 17, width: 8, height: 24)
        titleLabel.frame = CGRect(x: 30, y: 29, width: bounds.width - 42, height: 18)
        subtitleLabel.frame = CGRect(x: 30, y: 12, width: bounds.width - 42, height: 15)
    }

    func update(title: String, subtitle: String, accent: NSColor) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        accentView.layer?.backgroundColor = accent.cgColor
        needsLayout = true
    }
}

enum MouseGestureActionExecutor {
    @MainActor
    static func execute(_ action: MouseGestureAction, targetPID: pid_t) -> MouseGestureActionExecutionResult {
        guard targetPID > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return .failed(L10n.string(.MouseRuntime.gestureGestureTargetAppChangedActionCancelled))
        }
        switch action {
        case .none:
            return .succeeded
        case .navigateBack:
            return postKey(CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
        case .navigateForward:
            return postKey(CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
        case .missionControl:
            return postKey(CGKeyCode(kVK_UpArrow), flags: .maskControl)
        case .showDesktop:
            return postKey(CGKeyCode(kVK_F11), flags: [])
        case .applicationWindows:
            return postKey(CGKeyCode(kVK_DownArrow), flags: .maskControl)
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> MouseGestureActionExecutionResult {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return .failed(L10n.string(.MouseRuntime.gestureShortcutEventFailed))
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .succeeded
    }
}
