import ArcKitPlatform
import ArcKitMouse
import ApplicationServices
@preconcurrency import AppKit
import Foundation


/// 一次配置会话的输入管线。退役后旧 EventTap 即使迟到也只能透传，不能消费右键或滚轮。
final class MouseEventPipeline: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let settings: MouseEnhancementSettings
    private let scrollEngine = MouseScrollEngine()
    private let gestures: MouseGestureSession
    private let scrollSession: MouseScrollSession
    private let targetBundleIdentifierProvider: (pid_t) -> String?
    private var isActive = true
    private var statistics = MouseScrollDiagnostics()
    var diagnostics: MouseScrollDiagnostics {
        lock.withLock {
            var snapshot = statistics
            snapshot.output = scrollSession.outputStatistics
            return snapshot
        }
    }

    init(settings: MouseEnhancementSettings, scrollSession: MouseScrollSession,
         hintPresenter: MouseInputPresentation,
         rightClickReposter: @escaping (CGEvent, CGEvent) -> Void,
         targetBundleIdentifierProvider: @escaping (pid_t) -> String?) {
        self.gestures = MouseGestureSession(settings: settings.gestureSettings, hintPresenter: hintPresenter, rightClickReposter: rightClickReposter)
        self.settings = settings
        self.scrollSession = scrollSession
        self.targetBundleIdentifierProvider = targetBundleIdentifierProvider
    }

    var eventTypes: [CGEventType] {
        settings.gestureSettings.isEnabled
            ? [.scrollWheel, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
            : [.scrollWheel]
    }

    func handle(_ event: CGEvent) -> CGEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return event }
        switch event.type {
        case .scrollWheel: return handleScrollEvent(event)
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return gestures.handle(event)
        default: return event
        }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        isActive = false
        cancelPendingInput()
    }

    func cancelPendingInput() {
        lock.lock()
        defer { lock.unlock() }
        scrollSession.cancelPendingEvents()
        gestures.cancel()
    }

    private func handleScrollEvent(_ event: CGEvent) -> CGEvent? {
        guard event.type == .scrollWheel else {
            return event
        }
        let view = ScrollWheelEventView(event: event)
        guard !view.isSyntheticFromArcKit else {
            return event
        }

        let input = view.input
        if input.kind == .nativeGesture {
            statistics.nativeGestureInputs += 1
            scrollSession.cancelPendingEvents()
            return event
        }
        statistics.wheelInputs += 1
        // 空位移事件不应取消上一脉冲尚未完成的轨迹。
        guard input.verticalDelta != 0 || input.horizontalDelta != 0 else { return event }
        // 路由只从原始输入捕获一次，后续事件副本不能隐式重新决定投递目标。
        let destination = view.target
        statistics.targetProcessID = destination.processIdentifier
        statistics.targetWindowAvailable = destination.windowNumber > 0
        let bundle = targetBundleIdentifierProvider(destination.processIdentifier)
        statistics.targetBundleIdentifier = bundle
        let result = scrollEngine.transform(input: input, settings: settings, appBundleID: bundle)
        if case .passthrough = result {
            statistics.bypassedInputs += 1
            scrollSession.cancelPendingEvents()
            return event
        }
        // 被配置动作消费的修饰键不再传给应用，避免 Shift 再次换轴、Control 触发缩放。
        guard let context = event.copy(), let tuning = settings.effectiveTuning(for: bundle) else { return event }
        for modifier in [tuning.horizontalModifier, tuning.accelerationModifier, tuning.disableSmoothModifier] {
            switch modifier {
            case .shift: context.flags.remove(.maskShift)
            case .option: context.flags.remove(.maskAlternate)
            case .control: context.flags.remove(.maskControl)
            case .command: context.flags.remove(.maskCommand)
            case .none: break
            }
        }
        switch result {
        case .passthrough: return event
        case let .direct(vertical, horizontal):
            return scrollSession.handle(MouseScrollImpulse(verticalDelta: vertical, horizontalDelta: horizontal,
                                                           responseTimeMs: tuning.responseTimeMs), originalEvent: context, destination: destination, smooth: false)
        case let .smooth(impulse):
            return scrollSession.handle(impulse, originalEvent: context, destination: destination, smooth: true)
        }
    }
}
