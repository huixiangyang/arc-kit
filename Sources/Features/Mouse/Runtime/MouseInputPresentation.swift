import ArcKitMouse
import Foundation

/// 输入线程只提交轻量值；轨迹更新合并，避免主线程忙碌时积压每一个鼠标事件。
final class MouseInputPresentation: @unchecked Sendable {
    enum Effect: Sendable {
        case begin(CGPoint, Double), update(CGPoint, MouseGestureDecision, Double)
        case finish(CGPoint, MouseGestureDecision), execute(MouseGestureAction, CGPoint, pid_t, TimeInterval)
        case hideSoon, hide, overloaded
    }
    private let lock = NSLock()
    private var pending: [Effect] = []
    private var scheduled = false
    private var generation = 0
    private let consume: @MainActor @Sendable (Effect) -> Void
    init(consume: @escaping @MainActor @Sendable (Effect) -> Void) { self.consume = consume }

    private func submit(_ effect: Effect) {
        if Thread.isMainThread { MainActor.assumeIsolated { consume(effect) }; return }
        let shouldSchedule = lock.withLock {
            if case .update = effect, let last = pending.last, case .update = last { pending.removeLast() }
            // 主线程停顿时取消整批手势并显式报告，禁止在恢复后补执行积压动作。
            if pending.count >= 64 { pending = [.overloaded] }
            else if !pending.contains(where: { if case .overloaded = $0 { return true }; return false }) {
                pending.append(effect)
            }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule { DispatchQueue.main.async { [self] in drain() } }
    }

    @MainActor private func drain() {
        let (batch, expected) = lock.withLock {
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            scheduled = false
            return (batch, generation)
        }
        for effect in batch {
            guard lock.withLock({ generation == expected }) else { return }
            consume(effect)
        }
    }
    func begin(at point: CGPoint, threshold: Double) { submit(.begin(point, threshold)) }
    func update(current point: CGPoint, decision: MouseGestureDecision, threshold: Double) { submit(.update(point, decision, threshold)) }
    func finish(at point: CGPoint, decision: MouseGestureDecision) { submit(.finish(point, decision)) }
    func execute(_ action: MouseGestureAction, at point: CGPoint, targetPID: pid_t) {
        submit(.execute(action, point, targetPID, ProcessInfo.processInfo.systemUptime + 0.5))
    }
    func hideSoon() { submit(.hideSoon) }
    func cancel() {
        lock.withLock { pending.removeAll(keepingCapacity: true); generation += 1 }
        submit(.hide)
    }
}
