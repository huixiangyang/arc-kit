import ArcKitPlatform
import ArcKitWindow
import ApplicationServices
@preconcurrency import AppKit
import Combine
import Foundation

@MainActor
enum WindowDragSnapPreviewWindowFactory {
    static func makePreviewWindow() -> NSWindow {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.75).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 12
        panel.contentView = view
        return panel
    }
}

@MainActor
public final class WindowAgentDragSnapRuntime: ObservableObject {
    public enum State: Equatable {
        case stopped
        case waitingForAccessibility
        case running
        case failed(String)
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var lastFailureMessage: String?
    @Published public private(set) var lastPreviewFrame: CGRect?

    typealias EventTapFactory = ([CGEventType], @escaping EventTap.Handler) throws -> EventTapping

    private var sessionID = UUID()
    private var eventTap: EventTapping?
    private let eventTapFactory: EventTapFactory
    private let accessibilityTrusted: () -> Bool
    private var runtime = Runtime()
    private weak var windowService: WindowAgentRuntime?
    private var settings: WindowManagementSettings = .defaults
    private let policy = WindowDragSnapPolicy()
    private var previewWindow: NSWindow?

    public convenience init() {
        self.init(
            eventTapFactory: { events, handler in
                try EventTap(events: events, tapLocation: .cgSessionEventTap, handler: handler)
            },
            accessibilityTrusted: ProcessPermissions.accessibilityTrusted
        )
    }

    init(
        eventTapFactory: @escaping EventTapFactory,
        accessibilityTrusted: @escaping () -> Bool
    ) {
        self.eventTapFactory = eventTapFactory
        self.accessibilityTrusted = accessibilityTrusted
    }

    public func start(settings: WindowManagementSettings, windowService: WindowAgentRuntime) {
        stop()
        lastFailureMessage = nil
        guard settings.isEnabled else {
            state = .stopped
            ArcKitLog.append("window drag snap skipped reason=window-management-disabled")
            return
        }
        guard settings.dragSnapEnabled else {
            state = .stopped
            ArcKitLog.append("window drag snap skipped reason=drag-snap-disabled")
            return
        }
        guard accessibilityTrusted() else {
            state = .waitingForAccessibility
            ArcKitLog.append("window drag snap waiting reason=accessibility-not-trusted")
            return
        }
        self.settings = settings
        self.windowService = windowService
        do {
            let sessionID = self.sessionID
            let input = WindowDragInputChannel { [weak self] event in
                guard let self, self.sessionID == sessionID else { return }
                await self.handleOnMain(event: event)
            }
            eventTap = try eventTapFactory([.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { _, event in
                input.submit(event)
                return event
            }
            eventTap?.onStateChange = { [weak self] change in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self, self.sessionID == sessionID else { return }
                        self.handleEventTapStateChange(change)
                    }
                } else {
                    Task { @MainActor in
                        guard let self, self.sessionID == sessionID else { return }
                        self.handleEventTapStateChange(change)
                    }
                }
            }
            state = .running
            lastFailureMessage = nil
            ArcKitLog.append("window drag snap started preview=\(settings.showSnapPreview) gap=\(Int(settings.windowGap))")
        } catch {
            eventTap = nil
            state = .failed(L10n.string(.WindowRuntime.snappingSnappingStartFailed(String(describing: error.localizedDescription))))
            lastFailureMessage = L10n.string(.WindowRuntime.snappingSnappingStartFailed(String(describing: error.localizedDescription)))
            ArcKitLog.append("window drag snap failed error=\(error.localizedDescription)")
        }
    }

    public func stop() {
        sessionID = UUID()
        eventTap?.onStateChange = nil
        eventTap?.invalidate()
        eventTap = nil
        runtime.reset()
        hidePreview()
        lastPreviewFrame = nil
        lastFailureMessage = nil
        state = .stopped
    }

    private func handleEventTapStateChange(_ change: EventTapStateChange) {
        switch change {
        case .enabled:
            if eventTap?.isEnabled == true {
                state = .running
            } else {
                markEventTapRecoveryFailed(L10n.string(.WindowRuntime.snappingReadbackFailed))
            }
        case .disabledByTimeoutRecovered:
            confirmEventTapRecovered(
                warning: L10n.string(.WindowRuntime.snappingMacosDisabledSnappingTimeout),
                diagnostic: "window drag snap event tap timeout recovered"
            )
        case .recovered:
            confirmEventTapRecovered(
                warning: L10n.string(.WindowRuntime.snappingMacosDisabledSnappingRecoveredAutomatically),
                diagnostic: "window drag snap event tap recovered"
            )
        case .disabledByUserInput:
            state = .failed(L10n.string(.WindowRuntime.snappingMacosDisabledSnappingMonitoring))
            lastFailureMessage = L10n.string(.WindowRuntime.snappingMacosDisabledSnappingTurnWindowManagement)
            ArcKitLog.append("window drag snap event tap disabled by user input")
        case .invalidated:
            state = .failed(L10n.string(.WindowRuntime.snappingSnappingMonitorExpired))
            lastFailureMessage = L10n.string(.WindowRuntime.snappingSnappingMonitorExpiredTurnWindowManagement)
            ArcKitLog.append("window drag snap event tap invalidated")
        }
    }

    private func confirmEventTapRecovered(warning: String, diagnostic: String) {
        guard eventTap?.enable() == true, eventTap?.isEnabled == true else {
            markEventTapRecoveryFailed(L10n.string(.WindowRuntime.snappingSnappingRecoveryTurnWindowManagementFailed))
            return
        }
        state = .running
        lastFailureMessage = warning
        ArcKitLog.append(diagnostic)
    }

    private func markEventTapRecoveryFailed(_ message: String) {
        state = .failed(L10n.string(.WindowRuntime.snappingSnappingRecoveryFailed))
        lastFailureMessage = message
        ArcKitLog.append("window drag snap event tap recovery failed")
    }

    private func handleOnMain(event: WindowDragInput) async {
        switch event.type {
        case .leftMouseDown:
            await begin(event: event)
        case .leftMouseDragged:
            update(event: event)
        case .leftMouseUp:
            await finish(event: event)
        default:
            runtime.reset()
            hidePreview()
        }
    }

    private func begin(event: WindowDragInput) async {
        let sessionID = self.sessionID
        let candidate = await windowService?.windowTarget(at: event.location)
        guard sessionID == self.sessionID else { return }
        guard let candidate else { runtime.reset(); return }
        let frame = (try? await windowService?.frame(for: candidate.target)) ?? .null
        guard sessionID == self.sessionID else { return }
        guard Date().timeIntervalSince(event.capturedAt) < 1, !frame.isNull, !frame.isEmpty else {
            runtime.reset()
            return
        }
        let location = event.location
        guard policy.canBegin(at: location, windowFrame: frame, hitTestRoles: candidate.hitTestRoles) else {
            runtime.reset()
            return
        }
        runtime.state = Runtime.State(start: location, target: candidate.target, currentFrame: frame)
        ArcKitLog.append("window drag snap begin point=\(Int(location.x)),\(Int(location.y)) frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
    }

    private func update(event: WindowDragInput) {
        guard let state = runtime.state else { return }
        let location = event.location
        guard policy.hasMeaningfulDrag(from: state.start, to: location) else {
            return
        }
        let action = windowService?.snapAction(at: location)
        if settings.showSnapPreview, let action {
            // 拖拽吸附只会产生固定几何动作，按下时捕获的窗口 frame 已足够；
            // 禁止在高频 dragged 回调中重复跨进程读取 AX frame。
            showPreview(for: action, at: location, currentFrame: state.currentFrame)
        } else {
            hidePreview()
        }
    }

    private func finish(event: WindowDragInput) async {
        let sessionID = self.sessionID
        defer {
            if sessionID == self.sessionID { runtime.reset(); hidePreview() }
        }
        guard let state = runtime.state else { return }
        let location = event.location
        guard policy.hasMeaningfulDrag(from: state.start, to: location),
              let action = windowService?.snapAction(at: location)
        else {
            ArcKitLog.append("window drag snap cancelled at release point=\(Int(location.x)),\(Int(location.y))")
            return
        }
        ArcKitLog.append("window drag snap perform action=\(action.rawValue)")
        _ = await windowService?.perform(action, preferredTarget: state.target)
    }

    private func showPreview(for action: WindowLayoutAction, at point: CGPoint, currentFrame: CGRect) {
        guard let previewFrame = windowService?.snapPreviewFrame(for: action, at: point, currentFrame: currentFrame) else {
            hidePreview()
            return
        }
        guard lastPreviewFrame != previewFrame.accessibilityFrame || previewWindow?.isVisible != true else {
            return
        }
        lastPreviewFrame = previewFrame.accessibilityFrame

        let window = previewWindow ?? makePreviewWindow()
        previewWindow = window
        window.setFrame(previewFrame.appKitFrame, display: true)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func hidePreview() {
        previewWindow?.orderOut(nil)
        lastPreviewFrame = nil
    }

    private func makePreviewWindow() -> NSWindow {
        WindowDragSnapPreviewWindowFactory.makePreviewWindow()
    }
}

private final class Runtime {
    struct State {
        var start: CGPoint
        var target: WindowActionTarget
        var currentFrame: CGRect
    }

    var state: State?

    func reset() {
        state = nil
    }
}
