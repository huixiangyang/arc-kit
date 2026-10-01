import ApplicationServices
import Foundation

struct WindowDragInput: Sendable {
    let type: CGEventType
    let location: CGPoint
    let capturedAt: Date
}

/// 串行消费 down → dragged → up；只合并相邻移动，异步 AX 等待不会阻塞输入回调。
final class WindowDragInputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [WindowDragInput] = []
    private var draining = false
    private let consume: @MainActor @Sendable (WindowDragInput) async -> Void
    init(consume: @escaping @MainActor @Sendable (WindowDragInput) async -> Void) { self.consume = consume }
    func submit(_ event: CGEvent) {
        let input = WindowDragInput(type: event.type, location: event.location, capturedAt: Date())
        let start = lock.withLock {
            if input.type == .leftMouseDragged, pending.last?.type == .leftMouseDragged { pending.removeLast() }
            if pending.count >= 32 {
                // 丢弃过载手势并插入取消事件，禁止将下一笔 up 配给上一笔 down。
                pending = [WindowDragInput(type: .null, location: .zero, capturedAt: Date())]
            }
            pending.append(input)
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { Task { @MainActor [self] in await drain() } }
    }
    @MainActor private func drain() async {
        while let input = next() { await consume(input) }
    }
    private func next() -> WindowDragInput? {
        lock.withLock {
            guard !pending.isEmpty else { draining = false; return nil }
            return pending.removeFirst()
        }
    }
}
