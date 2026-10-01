import Foundation

/// 单一剩余目标，按剩余时长积分三次缓出。最后一次输入后在 responseTimeMs 内收敛，
/// 刷新率只影响采样密度，不影响距离；反向立即撤销该轴的旧尾段。
public struct MouseSmoothScrollModel: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var verticalDelta: Double
        public var horizontalDelta: Double
        public init(verticalDelta: Double, horizontalDelta: Double) {
            self.verticalDelta = verticalDelta
            self.horizontalDelta = horizontalDelta
        }
    }
    private var vertical = 0.0
    private var horizontal = 0.0
    private var remainingSeconds = 0.0
    public init() {}
    public var hasPendingOutput: Bool { vertical != 0 || horizontal != 0 }

    public mutating func enqueue(_ impulse: MouseScrollImpulse) {
        guard impulse.verticalDelta.isFinite, impulse.horizontalDelta.isFinite,
              (80...320).contains(impulse.responseTimeMs) else { return }
        Self.merge(impulse.verticalDelta, into: &vertical)
        Self.merge(impulse.horizontalDelta, into: &horizontal)
        remainingSeconds = Double(impulse.responseTimeMs) / 1_000
    }

    public mutating func nextFrame(elapsedSeconds: Double) -> Frame? {
        guard hasPendingOutput, elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        let nextRemaining = max(0, remainingSeconds - elapsedSeconds)
        let fraction = remainingSeconds > 0 ? 1 - pow(nextRemaining / remainingSeconds, 3) : 1
        let frame = Frame(verticalDelta: vertical * fraction, horizontalDelta: horizontal * fraction)
        vertical -= frame.verticalDelta
        horizontal -= frame.horizontalDelta
        remainingSeconds = nextRemaining
        return frame
    }

    public mutating func reset() { self = Self() }

    private static func merge(_ delta: Double, into remaining: inout Double) {
        guard delta != 0 else { return }
        remaining = remaining != 0 && remaining.sign != delta.sign ? delta : remaining + delta
    }
}
