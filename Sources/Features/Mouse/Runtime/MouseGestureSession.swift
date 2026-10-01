import ArcKitPlatform
import ArcKitMouse
import ApplicationServices
import Foundation

/// 仅由 MouseEventPipeline 的锁串行访问，不再嵌套一次同步队列跳转。
final class MouseGestureSession {
    private let settings: MouseGestureSettings
    private let gestureEngine = MouseGestureEngine()
    private let gestureRuntime = MouseGestureStroke()
    private let hintPresenter: MouseInputPresentation
    private let rightClickReposter: (CGEvent, CGEvent) -> Void
    init(settings: MouseGestureSettings, hintPresenter: MouseInputPresentation,
         rightClickReposter: @escaping (CGEvent, CGEvent) -> Void) {
        self.settings = settings
        self.hintPresenter = hintPresenter
        self.rightClickReposter = rightClickReposter
    }
    func cancel() {
        hintPresenter.cancel()
        guard let pending = gestureRuntime.cancelPending(),
              let up = Self.makeRightMouseUpEvent(matching: pending.downEvent) else { return }
        rightClickReposter(pending.downEvent, up)
    }
    func handle(_ event: CGEvent) -> CGEvent? {
        guard settings.isEnabled else {
            return event
        }
        guard !Self.isSyntheticEvent(event) else {
            return event
        }

        switch event.type {
        case .rightMouseDown:
            if let interrupted = gestureRuntime.begin(with: event),
               let upEvent = Self.makeRightMouseUpEvent(matching: interrupted.downEvent) {
                // 极端情况下系统可能漏掉上一笔 rightMouseUp；新按下不能直接覆盖已吞事件，否则普通右键会永久丢失。
                rightClickReposter(interrupted.downEvent, upEvent)
                ArcKitLog.append("mouse gesture recovered interrupted right click before new down")
            }
            if settings.showVisualHint {
                hintPresenter.begin(at: event.location, threshold: settings.minimumDistance)
            }
            return nil
        case .rightMouseDragged:
            guard gestureRuntime.snapshot() != nil else {
                return event
            }
            gestureRuntime.update(currentLocation: event.location)
            if settings.showVisualHint,
               let state = gestureRuntime.snapshot() {
                let input = MouseGestureInput(
                    startX: state.startLocation.x,
                    startY: state.startLocation.y,
                    currentX: event.location.x,
                    currentY: event.location.y
                )
                hintPresenter.update(
                    current: event.location,
                    decision: gestureEngine.decide(input: input, settings: settings),
                    threshold: settings.minimumDistance
                )
            }
            return nil
        case .rightMouseUp:
            let state = gestureRuntime.finish(currentLocation: event.location)
            guard let state else {
                hintPresenter.hideSoon()
                return event
            }
            let input = MouseGestureInput(
                startX: state.startLocation.x,
                startY: state.startLocation.y,
                currentX: state.endLocation.x,
                currentY: state.endLocation.y
            )
            let decision = gestureEngine.decide(input: input, settings: settings)
            if settings.showVisualHint {
                hintPresenter.finish(at: event.location, decision: decision)
            }
            if let result = decision.result {
                hintPresenter.execute(result.action, at: event.location, targetPID: ScrollWheelEventView(event: state.downEvent).target.processIdentifier)
                return nil
            }
            if decision.shouldRepostRightClick {
                rightClickReposter(state.downEvent, event)
            }
            return nil
        default:
            return event
        }
    }

    static func repostRightClick(downEvent: CGEvent, upEvent: CGEvent) {
        guard let downCopy = downEvent.copy(), let upCopy = upEvent.copy() else {
            return
        }
        markSyntheticEvent(downCopy)
        markSyntheticEvent(upCopy)
        let target = ScrollWheelEventView(event: downEvent).target.processIdentifier
        downCopy.timestamp = DispatchTime.now().uptimeNanoseconds
        upCopy.timestamp = downCopy.timestamp + 1
        if target > 0 {
            downCopy.postToPid(target)
            upCopy.postToPid(target)
        } else {
            downCopy.post(tap: .cgSessionEventTap)
            upCopy.post(tap: .cgSessionEventTap)
        }
    }

    private static func makeRightMouseUpEvent(matching downEvent: CGEvent) -> CGEvent? {
        guard let upEvent = downEvent.copy() else { return nil }
        // 复制原始事件后只改变类型，保留 clickState、pressure、flags、location 和设备相关字段。
        upEvent.type = .rightMouseUp
        return upEvent
    }

    private static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == MouseScrollEventOrigin.syntheticMarker
    }

    private static func markSyntheticEvent(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: MouseScrollEventOrigin.syntheticMarker)
    }
}

private final class MouseGestureStroke {
    struct State {
        var downEvent: CGEvent
        var startLocation: CGPoint
        var endLocation: CGPoint
    }
    private var state: State?
    func begin(with event: CGEvent) -> State? {
        let previous = state
        state = State(downEvent: event.copy() ?? event, startLocation: event.location, endLocation: event.location)
        return previous
    }
    func update(currentLocation: CGPoint) { state?.endLocation = currentLocation }
    func finish(currentLocation: CGPoint) -> State? {
        defer { state = nil }
        state?.endLocation = currentLocation
        return state
    }
    func snapshot() -> State? { state }
    func cancelPending() -> State? { defer { state = nil }; return state }
}
