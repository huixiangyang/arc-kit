import ArcKitPlatform
import ArcKitMouse
import ApplicationServices
import Foundation

typealias MouseSmoothEventPoster = @Sendable (CGEvent, pid_t) -> Void
typealias MouseSmoothEventDeliveryScheduler = @Sendable (_ work: @escaping @Sendable () -> Void) -> Void

enum MouseSmoothScrollExecution {
    private static let queue = DispatchQueue(label: "com.archalo.arckit.mouse-scroll-post", qos: .userInteractive)
    static func postToTargetProcess(_ event: CGEvent, _ pid: pid_t) { event.postToPid(pid) }
    static func deliverOnProductionQueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

/// 一个配置会话只持有一个目标和一条轨迹。帧回调只合并位移，最多排队一个投递任务。
/// 输入、取消和实际 post 共用投递门：cancel 返回后旧帧不可能再开始投递。
/// 显示回调只获取状态锁，不等待系统 post 调用；慢消费者只能合并位移，不能积压闭包。
final class MouseScrollSession: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryGate = NSRecursiveLock()
    private let eventPoster: MouseSmoothEventPoster
    private let frameDriver: MouseSmoothScrollFrameDriving
    private let scheduleDelivery: MouseSmoothEventDeliveryScheduler
    private var model = MouseSmoothScrollModel()
    private var pixels = MouseScrollPixelAccumulator()
    private var context: CGEvent?
    private var target: MouseScrollTarget?
    private var lastInputTime = 0.0
    private var lastFrameTime: CFTimeInterval?
    private var running = false
    private var generation = 0
    private var pendingVertical = 0.0
    private var pendingHorizontal = 0.0
    private var deliveryScheduled = false
    private var lastDirectionY = 0.0
    private var lastDirectionX = 0.0
    private var issueChangeHandler: (@Sendable () -> Void)?
    private var currentIssue: String?
    private var statistics = MouseScrollOutputStatistics()
    var outputStatistics: MouseScrollOutputStatistics { lock.withLock { statistics } }
    var runtimeIssue: String? { lock.withLock { currentIssue } }
    var onRuntimeIssueChange: (@Sendable () -> Void)? {
        get { lock.withLock { issueChangeHandler } }
        set { lock.withLock { issueChangeHandler = newValue } }
    }

    init(eventPoster: @escaping MouseSmoothEventPoster, frameDriver: MouseSmoothScrollFrameDriving,
         eventDeliveryScheduler: @escaping MouseSmoothEventDeliveryScheduler) {
        self.eventPoster = eventPoster
        self.frameDriver = frameDriver
        self.scheduleDelivery = eventDeliveryScheduler
    }

    func resetStatistics() { lock.withLock { statistics = MouseScrollOutputStatistics(); currentIssue = nil } }

    func handle(_ impulse: MouseScrollImpulse, originalEvent: CGEvent, destination: MouseScrollTarget, smooth: Bool) -> CGEvent? {
        deliveryGate.lock()
        defer { deliveryGate.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard let copy = originalEvent.copy() else { return originalEvent }
        lock.lock()
        if target != destination || now - lastInputTime >= 0.45 {
            resetLocked()
        }
        target = destination
        context = copy
        lastInputTime = now
        // 取消尚未投递的反向尾量，包括量化余数。另一轴的轨迹不受影响。
        if impulse.verticalDelta != 0, lastDirectionY != 0, lastDirectionY.sign != impulse.verticalDelta.sign { pendingVertical = 0 }
        if impulse.horizontalDelta != 0, lastDirectionX != 0, lastDirectionX.sign != impulse.horizontalDelta.sign { pendingHorizontal = 0 }
        pixels.discardOpposite(to: (impulse.verticalDelta, impulse.horizontalDelta))
        if impulse.verticalDelta != 0 { lastDirectionY = impulse.verticalDelta }
        if impulse.horizontalDelta != 0 { lastDirectionX = impulse.horizontalDelta }

        if !smooth || !destination.canReceivePostedScroll {
            model.reset()
            pendingVertical = 0
            pendingHorizontal = 0
            running = false
            lastFrameTime = nil
            generation += 1
            let failures = statistics.creationFailures
            let result = makeOutputLocked(vertical: impulse.verticalDelta, horizontal: impulse.horizontalDelta)
            let creationFailed = statistics.creationFailures != failures
            lock.unlock()
            frameDriver.stop()
            if smooth { reportFallback(L10n.string(.MouseRuntime.sessionScrollInputLacksTargetProcess)) }
            return creationFailed ? originalEvent : result
        }

        model.enqueue(impulse)
        let shouldStart = !running
        running = true
        // 每个新脉冲更新驱动代次，防止上一帧的异步停止关闭新轨迹。
        generation += 1
        let currentGeneration = generation
        if shouldStart { lastFrameTime = nil }
        lock.unlock()
        guard frameDriver.start(frameHandler: { [weak self] timestamp, duration in
            self?.frame(timestamp: timestamp, duration: duration, generation: currentGeneration) ?? false
        }) else {
            lock.lock()
            model.reset()
            running = false
            pendingVertical = 0
            pendingHorizontal = 0
            let failures = statistics.creationFailures
            let output = makeOutputLocked(vertical: impulse.verticalDelta, horizontal: impulse.horizontalDelta)
            let creationFailed = statistics.creationFailures != failures
            lock.unlock()
            reportFallback(L10n.string(.MouseRuntime.sessionDirectScrollFallback))
            return creationFailed ? originalEvent : output
        }
        return nil
    }

    func cancelPendingEvents() {
        // 先撤销待发送数据，再等已开始的 post 完成。不能先等投递门，否则排队帧可能抢先获得门继续发送。
        // 新物理输入与本方法由 MouseEventPipeline 串行调用。
        lock.withLock { resetLocked() }
        deliveryGate.lock()
        deliveryGate.unlock()
        // 不能持有状态锁等待 CVDisplayLink 回调退出。
        frameDriver.stop()
    }

    private func resetLocked() {
        model.reset()
        pixels = MouseScrollPixelAccumulator()
        context = nil
        target = nil
        lastInputTime = 0
        lastFrameTime = nil
        lastDirectionY = 0
        lastDirectionX = 0
        running = false
        pendingVertical = 0
        pendingHorizontal = 0
        generation += 1
        // 已排队的唯一任务保留名额，但读取不到旧数据；频繁启停不会堆积失效闭包。
    }

    private func frame(timestamp: CFTimeInterval, duration: CFTimeInterval, generation expected: Int) -> Bool {
        lock.lock()
        guard generation == expected, running else { lock.unlock(); return false }
        let measured = lastFrameTime.map { timestamp - $0 }
        let elapsed = measured.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? duration
        lastFrameTime = timestamp
        if let frame = model.nextFrame(elapsedSeconds: elapsed) {
            pendingVertical += frame.verticalDelta
            pendingHorizontal += frame.horizontalDelta
        }
        let hasMore = model.hasPendingOutput
        running = hasMore
        let shouldSchedule = !deliveryScheduled && (pendingVertical != 0 || pendingHorizontal != 0)
        if shouldSchedule { deliveryScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleDelivery { [weak self] in self?.deliver() } }
        return hasMore
    }

    private func deliver() {
        deliveryGate.lock()
        defer { deliveryGate.unlock() }
        lock.lock()
        deliveryScheduled = false
        guard let target, target.canReceivePostedScroll else { lock.unlock(); return }
        let failures = statistics.creationFailures
        let output = makeOutputLocked(vertical: pendingVertical, horizontal: pendingHorizontal)
        pendingVertical = 0
        pendingHorizontal = 0
        if statistics.creationFailures != failures {
            resetLocked()
            currentIssue = L10n.string(.MouseRuntime.sessionEventCreationFailed)
            let callback = issueChangeHandler
            lock.unlock()
            callback?()
            return
        }
        lock.unlock()
        if let output {
            // CGEventPostToPid 不提供送达回执；这里只能计为已提交，不能计为目标应用已消费。
            eventPoster(output, target.processIdentifier)
            let callback = lock.withLock { () -> (@Sendable () -> Void)? in
                statistics.postedFrames += 1
                // 真正提交平滑帧后才能撤销降级提示，不能仅凭 start 返回成功。
                guard currentIssue != nil else { return nil }
                currentIssue = nil
                return issueChangeHandler
            }
            callback?()
        }
    }

    private func makeOutputLocked(vertical: Double, horizontal: Double) -> CGEvent? {
        guard let context else { return nil }
        let previousPixels = pixels
        let delta = pixels.take(vertical: vertical, horizontal: horizontal)
        guard delta.vertical != 0 || delta.horizontal != 0 else { return nil }
        guard let event = MouseScrollEventFactory.make(vertical: delta.vertical, horizontal: delta.horizontal, context: context) else {
            statistics.creationFailures += 1
            pixels = previousPixels
            // 直接模式由调用方透传原事件，异步模式由 deliver 报告并终止轨迹。
            return nil
        }
        statistics.generatedEvents += 1
        statistics.verticalPixels += Int64(delta.vertical)
        statistics.horizontalPixels += Int64(delta.horizontal)
        return event
    }

    private func reportFallback(_ message: String) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            statistics.directFallbacks += 1
            guard currentIssue != message else { return nil }
            currentIssue = message
            return issueChangeHandler
        }
        callback?()
    }
}
