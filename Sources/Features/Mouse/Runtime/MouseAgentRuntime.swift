import ArcKitPlatform
import ArcKitMouse
import ApplicationServices
import Combine
import Foundation


@MainActor
public final class MouseAgentRuntime: ObservableObject {
    public enum State: Equatable {
        case stopped
        case running
        case failedToCreateEventTap
        case disabledByUserInput
        case eventTapInvalidated
    }

    typealias EventTapFactory = ([CGEventType], @escaping EventTap.Handler) throws -> EventTapping

    private var eventTap: EventTapping?
    private var pipeline: MouseEventPipeline?
    private var sessionID = UUID()
    private let eventTapFactory: EventTapFactory
    private let gestureActionExecutor: (MouseGestureAction, pid_t) -> MouseGestureActionExecutionResult
    private let rightClickReposter: (CGEvent, CGEvent) -> Void
    private let scrollSession: MouseScrollSession
    private let applicationRegistry: MouseApplicationRegistry?
    private let targetBundleIdentifierProvider: (pid_t) -> String?
    private let gestureHintPresenter: MouseGestureHintPresenting
    private var smoothRuntimeIssue: String?
    @Published public private(set) var state: State = .stopped
    @Published public private(set) var lastRuntimeWarning: String?
    @Published public private(set) var lastFailureReason: String?

    public var isRunning: Bool {
        state == .running
    }

    public convenience init() {
        self.init(eventTapFactory: { events, handler in
            // 按 PID 投递必须取得 WindowServer 已标注窗口的事件；session 阶段只有 PID 仍不足以路由。
            try EventTap(events: events, tapLocation: .cgAnnotatedSessionEventTap, handler: handler)
        })
    }

    init(
        eventTapFactory: @escaping EventTapFactory,
        gestureActionExecutor: @escaping (MouseGestureAction, pid_t) -> MouseGestureActionExecutionResult = { MouseGestureActionExecutor.execute($0, targetPID: $1) },
        rightClickReposter: @escaping (CGEvent, CGEvent) -> Void = MouseGestureSession.repostRightClick,
        smoothEventPoster: @escaping MouseSmoothEventPoster = MouseSmoothScrollExecution.postToTargetProcess,
        smoothFrameDriver: MouseSmoothScrollFrameDriving? = nil,
        smoothEventDeliveryScheduler: MouseSmoothEventDeliveryScheduler? = nil,
        targetBundleIdentifierProvider: ((pid_t) -> String?)? = nil,
        gestureHintPresenter: MouseGestureHintPresenting = MouseGestureHintPresenter()
    ) {
        self.eventTapFactory = eventTapFactory
        self.gestureActionExecutor = gestureActionExecutor
        self.rightClickReposter = rightClickReposter
        let frameDriver = smoothFrameDriver ?? DisplayLinkedMouseSmoothScrollFrameDriver()
        let deliveryScheduler = smoothEventDeliveryScheduler ?? MouseSmoothScrollExecution.deliverOnProductionQueue
        self.scrollSession = MouseScrollSession(
            eventPoster: smoothEventPoster,
            frameDriver: frameDriver,
            eventDeliveryScheduler: deliveryScheduler
        )
        if let targetBundleIdentifierProvider {
            self.applicationRegistry = nil
            self.targetBundleIdentifierProvider = targetBundleIdentifierProvider
        } else {
            let tracker = MouseApplicationRegistry()
            self.applicationRegistry = tracker
            let provider: @Sendable (pid_t) -> String? = { [weak tracker] pid in
                tracker?.bundleIdentifier(for: pid)
            }
            self.targetBundleIdentifierProvider = provider
        }
        self.gestureHintPresenter = gestureHintPresenter
    }

    public var scrollDiagnostics: MouseScrollDiagnostics { pipeline?.diagnostics ?? MouseScrollDiagnostics() }

    public func start(settings: MouseEnhancementSettings) {
        stop()
        guard settings.isEnabled else {
            state = .stopped
            return
        }
        lastRuntimeWarning = nil
        lastFailureReason = nil
        scrollSession.resetStatistics()
        do {
            let sessionID = self.sessionID
            let presentation = MouseInputPresentation { [weak self] effect in
                guard let self, self.sessionID == sessionID else { return }
                switch effect {
                case let .begin(point, threshold): self.gestureHintPresenter.begin(at: point, threshold: threshold)
                case let .update(point, decision, threshold): self.gestureHintPresenter.update(current: point, decision: decision, threshold: threshold)
                case let .finish(point, decision): self.gestureHintPresenter.finish(at: point, decision: decision)
                case .hideSoon: self.gestureHintPresenter.hideSoon()
                case .hide: self.gestureHintPresenter.hideImmediately()
                case .overloaded:
                    self.gestureHintPresenter.hideImmediately()
                    self.lastRuntimeWarning = L10n.string(.MouseRuntime.monitorGestureProcessingOverloadedBatchCancelled)
                case let .execute(action, point, targetPID, deadline):
                    let result: MouseGestureActionExecutionResult = ProcessInfo.processInfo.systemUptime <= deadline
                        ? self.gestureActionExecutor(action, targetPID)
                        : .failed(L10n.string(.MouseRuntime.monitorGestureExecutionExpiredRetry))
                    self.handleGestureActionResult(action: action, result: result)
                    if case let .failed(message) = result { self.gestureHintPresenter.fail(at: point, message: message) }
                }
            }
            let pipeline = MouseEventPipeline(
                settings: settings, scrollSession: scrollSession, hintPresenter: presentation,
                rightClickReposter: rightClickReposter,
                targetBundleIdentifierProvider: targetBundleIdentifierProvider
            )
            self.pipeline = pipeline
            scrollSession.onRuntimeIssueChange = { [weak self] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        guard let self, self.sessionID == sessionID else { return }
                        self.recordSmoothRuntimeIssue()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sessionID else { return }
                        self.recordSmoothRuntimeIssue()
                    }
                }
            }
            eventTap = try eventTapFactory(pipeline.eventTypes) { _, event in pipeline.handle(event) }
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
            guard eventTap?.isEnabled == true else {
                pipeline.invalidate()
                eventTap?.onStateChange = nil
                eventTap?.invalidate()
                eventTap = nil
                self.pipeline = nil
                markEventTapRecoveryFailed(L10n.string(.MouseRuntime.monitorMouseMonitorCreatedDisabled))
                return
            }
            state = .running
        } catch {
            pipeline?.invalidate()
            pipeline = nil
            eventTap = nil
            lastFailureReason = error.localizedDescription
            lastRuntimeWarning = nil
            state = .failedToCreateEventTap
            ArcKitLog.append("mouse event tap create failed error=\(error.localizedDescription)")
        }
    }

    public func stop() {
        // 先使会话失效，再取消系统资源；已经排入主线程的旧回调不得污染新会话。
        sessionID = UUID()
        pipeline?.invalidate()
        pipeline = nil
        gestureHintPresenter.hideImmediately()
        scrollSession.onRuntimeIssueChange = nil
        smoothRuntimeIssue = nil
        eventTap?.onStateChange = nil
        eventTap?.invalidate()
        eventTap = nil
        lastRuntimeWarning = nil
        lastFailureReason = nil
        state = .stopped
    }

    public func reportConfigurationFailure(_ message: String) {
        lastRuntimeWarning = message
        lastFailureReason = message
        ArcKitLog.append("mouse configuration failed message=\(message)")
    }

    private func recordSmoothRuntimeIssue() {
        // 跨线程只通知变更，在主线程读取当前事实，避免迟到的失败消息盖过已经恢复的状态。
        let message = scrollSession.runtimeIssue
        let previous = smoothRuntimeIssue
        guard message != previous else { return }
        smoothRuntimeIssue = message
        if let message {
            lastRuntimeWarning = message
            lastFailureReason = message
            ArcKitLog.append("mouse smooth runtime degraded message=\(message)")
        } else {
            // 只清除此组件的旧异常，保留后续手势或 EventTap 报告的问题。
            if lastRuntimeWarning == previous { lastRuntimeWarning = nil }
            if lastFailureReason == previous { lastFailureReason = nil }
            ArcKitLog.append("mouse smooth runtime recovered after frame submission")
        }
    }

    private func handleGestureActionResult(
        action: MouseGestureAction,
        result: MouseGestureActionExecutionResult
    ) {
        switch result {
        case .succeeded:
            ArcKitLog.append("mouse gesture action success action=\(action.rawValue)")
        case let .failed(message):
            lastRuntimeWarning = message
            lastFailureReason = message
            ArcKitLog.append("mouse gesture action failed action=\(action.rawValue) message=\(message)")
        }
    }

    private func handleEventTapStateChange(_ change: EventTapStateChange) {
        switch change {
        case .enabled:
            if eventTap?.isEnabled == true {
                state = .running
            } else {
                markEventTapRecoveryFailed(L10n.string(.MouseRuntime.monitorReadbackFailed))
            }
        case .disabledByTimeoutRecovered:
            pipeline?.cancelPendingInput()
            confirmEventTapRecovered(
                warning: L10n.string(.MouseRuntime.monitorMacosDisabledMouseMonitoringTimeout),
                diagnostic: "mouse event tap disabled by timeout recovered"
            )
        case .disabledByUserInput:
            pipeline?.cancelPendingInput()
            state = .disabledByUserInput
            lastRuntimeWarning = L10n.string(.MouseRuntime.monitorMacosDisabledMouseMonitoringArcKit)
            ArcKitLog.append("mouse event tap disabled by user input")
        case .invalidated:
            pipeline?.cancelPendingInput()
            state = .eventTapInvalidated
            lastRuntimeWarning = L10n.string(.MouseRuntime.monitorExpiredRecoveryHint)
            ArcKitLog.append("mouse event tap invalidated")
        case .recovered:
            pipeline?.cancelPendingInput()
            confirmEventTapRecovered(
                warning: L10n.string(.MouseRuntime.monitorRecovered),
                diagnostic: "mouse event tap recovered"
            )
        }
    }

    private func confirmEventTapRecovered(warning: String, diagnostic: String) {
        guard eventTap?.enable() == true, eventTap?.isEnabled == true else {
            markEventTapRecoveryFailed(L10n.string(.MouseRuntime.monitorFailedRecoveryHint))
            return
        }
        state = .running
        lastRuntimeWarning = warning
        ArcKitLog.append(diagnostic)
    }

    private func markEventTapRecoveryFailed(_ message: String) {
        state = .eventTapInvalidated
        lastRuntimeWarning = message
        ArcKitLog.append("mouse event tap recovery failed")
    }

}
