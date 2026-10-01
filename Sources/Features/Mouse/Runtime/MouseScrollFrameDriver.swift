import CoreVideo
import ArcKitPlatform
import Foundation

protocol MouseSmoothScrollFrameDriving: AnyObject, Sendable {
    func start(frameHandler: @escaping @Sendable (CFTimeInterval, CFTimeInterval) -> Bool) -> Bool
    func stop()
}

/// 默认运行时跟随真实显示刷新率，不再假定屏幕固定为 125Hz。
final class DisplayLinkedMouseSmoothScrollFrameDriver: MouseSmoothScrollFrameDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "com.archalo.arckit.scroll-display-control")
    private var displayLink: CVDisplayLink?
    private var frameHandler: (@Sendable (CFTimeInterval, CFTimeInterval) -> Bool)?
    private var generation = 0
    private var retryAfter: CFTimeInterval = 0
    private let createDisplayLink: @Sendable () -> CVDisplayLink?
    private let startDisplayLink: @Sendable (CVDisplayLink) -> CVReturn
    private let uptime: @Sendable () -> CFTimeInterval

    init(createDisplayLink: @escaping @Sendable () -> CVDisplayLink? = DisplayLinkedMouseSmoothScrollFrameDriver.makeDisplayLink,
         startDisplayLink: @escaping @Sendable (CVDisplayLink) -> CVReturn = { CVDisplayLinkStart($0) },
         uptime: @escaping @Sendable () -> CFTimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.createDisplayLink = createDisplayLink
        self.startDisplayLink = startDisplayLink
        self.uptime = uptime
        // Host 可能在锁屏或无活动显示器时启动，不能把当时的创建失败固化到整个进程寿命。
    }

    static func makeDisplayLink() -> CVDisplayLink? {
        var created: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard result == kCVReturnSuccess else {
            ArcKitLog.append("mouse display link create failed code=\(result)")
            return nil
        }
        return created
    }

    private func createOnControlQueue() -> Bool {
        guard uptime() >= retryAfter else { return false }
        guard let created = createDisplayLink() else {
            retryAfter = uptime() + 0.5
            return false
        }
        let callbackResult = CVDisplayLinkSetOutputCallback(
            created,
            { displayLink, _, outputTime, _, _, context in
                guard let context else { return kCVReturnError }
                let driver = Unmanaged<DisplayLinkedMouseSmoothScrollFrameDriver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return driver.handleFrame(displayLink: displayLink, outputTime: outputTime.pointee)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard callbackResult == kCVReturnSuccess else {
            ArcKitLog.append("mouse display link callback setup failed code=\(callbackResult)")
            retryAfter = uptime() + 0.5
            return false
        }
        displayLink = created
        retryAfter = 0
        return true
    }

    deinit {
        stop()
    }

    func start(frameHandler: @escaping @Sendable (CFTimeInterval, CFTimeInterval) -> Bool) -> Bool {
        controlQueue.sync { startOnControlQueue(frameHandler) }
    }

    private func startOnControlQueue(_ frameHandler: @escaping @Sendable (CFTimeInterval, CFTimeInterval) -> Bool) -> Bool {
        // 按真实滚动需求创建；显示器恢复后下一次输入即可重试，失败时最多每半秒创建一次。
        if displayLink == nil, !createOnControlQueue() { return false }
        lock.lock()
        generation += 1
        self.frameHandler = frameHandler
        let displayLink = displayLink
        lock.unlock()
        guard let displayLink else { return false }
        if CVDisplayLinkIsRunning(displayLink) { return true }
        let result = startDisplayLink(displayLink)
        guard result != kCVReturnSuccess else { return true }
        ArcKitLog.append("mouse display link start failed code=\(result); recreate on next input")
        // 休眠或显示器变化可能留下失效对象，不能对同一个对象永久重试。
        stopOnControlQueue()
        self.displayLink = nil
        retryAfter = uptime() + 0.5
        return false
    }

    func stop() { controlQueue.sync { stopOnControlQueue() } }

    private func stopOnControlQueue() {
        lock.lock()
        generation += 1
        frameHandler = nil
        let displayLink = displayLink
        lock.unlock()
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    private func handleFrame(displayLink: CVDisplayLink, outputTime: CVTimeStamp) -> CVReturn {
        lock.lock()
        let frameHandler = frameHandler
        let activeGeneration = generation
        lock.unlock()
        guard let frameHandler else { return kCVReturnSuccess }
        let frequency = CVGetHostClockFrequency()
        let timestamp = frequency > 0
            ? CFTimeInterval(outputTime.hostTime) / frequency
            : ProcessInfo.processInfo.systemUptime
        let timestampFrameDuration = outputTime.videoTimeScale > 0 && outputTime.videoRefreshPeriod > 0
            ? CFTimeInterval(outputTime.videoRefreshPeriod) / CFTimeInterval(outputTime.videoTimeScale)
            : 0
        let actualFrameDuration = CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
        let frameDuration = timestampFrameDuration > 0
            ? timestampFrameDuration
            : (actualFrameDuration > 0 ? actualFrameDuration : (1.0 / 60.0))
        if !frameHandler(timestamp, frameDuration) {
            // CVDisplayLinkStop 不在回调线程执行，避免等待当前回调造成死锁。
            controlQueue.async { [weak self] in
                self?.stopIfCurrent(generation: activeGeneration)
            }
        }
        return kCVReturnSuccess
    }

    private func stopIfCurrent(generation expectedGeneration: Int) {
        lock.lock()
        guard generation == expectedGeneration else {
            lock.unlock()
            return
        }
        generation += 1
        frameHandler = nil
        let displayLink = displayLink
        lock.unlock()
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }
}
