@testable import ArcKitMouseRuntime
import ArcKitMouse
import ArcKitPlatform
import AppKit
import CoreVideo
import Testing

/// 全部事件只交给内存中的 AppKit 消费者，不创建系统 tap、不向其他应用发输入。
@Suite("鼠标输入到 AppKit 消费", .serialized)
@MainActor
struct MouseScrollPipelineTests {
    @Test("UU 默认原样放行并取消旧尾段，修改或删除规则后恢复增强")
    func uuRemoteRuleControlsPipeline() throws {
        let work = LockedTestValue([@Sendable () -> Void]())
        let harness = Harness(provider: { $0 == 222 ? "com.netease.uuremote" : "com.google.Chrome" },
                              delivery: { task in work.mutate { $0.append(task) } })
        defer { harness.runtime.stop() }
        #expect(harness.send(try makeScrollWheelEvent(verticalDelta: 1)) == nil)
        harness.driver.tick()
        let remote = try makeScrollWheelEvent(verticalDelta: 1, targetProcessIdentifier: 222)
        remote.flags = [.maskShift, .maskControl]
        #expect(harness.send(remote) === remote)
        #expect(remote.flags == [.maskShift, .maskControl])
        for task in work.read({ $0 }) { task() }
        #expect(harness.outputs.read { $0.isEmpty })
        #expect(harness.runtime.scrollDiagnostics.bypassedInputs == 1)

        var settings = MouseEnhancementSettings.defaults
        settings.appProfiles[0].behavior = .custom
        settings.appProfiles[0].tuning.smoothEnabled = false
        settings.appProfiles[0].tuning.reverseVertical = false
        let custom = Harness(settings: settings, provider: { _ in "com.netease.uuremote" })
        defer { custom.runtime.stop() }
        remote.flags = []
        #expect(NSEvent(cgEvent: try #require(custom.send(remote)))?.scrollingDeltaY == 91)
        settings.removeAppProfile(id: settings.appProfiles[0].id)
        let deleted = Harness(settings: settings, provider: { _ in "com.netease.uuremote" })
        defer { deleted.runtime.stop() }
        #expect(deleted.send(remote) == nil)
        deleted.driver.drain()
        #expect(deleted.outputs.read { !$0.isEmpty && $0.allSatisfy { (NSEvent(cgEvent: $0)?.scrollingDeltaY ?? 0) < 0 } })
    }

    @Test("像素构造、行单位回退与零输入")
    func units() throws {
        let event = try makeScrollWheelEvent(verticalDelta: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.5)
        #expect(ScrollWheelEventView(event: event).input.verticalDelta == 25)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        #expect(ScrollWheelEventView(event: event).input.verticalDelta == 0)
        event.timestamp = 1
        let output = try #require(MouseScrollEventFactory.make(vertical: -3, horizontal: 2, context: event))
        let native = try #require(NSEvent(cgEvent: output))
        #expect(native.hasPreciseScrollingDeltas)
        #expect(native.scrollingDeltaY == -3 && native.scrollingDeltaX == 2)
        #expect(abs(output.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + 0.3) < 0.0001)
        #expect(output.timestamp > event.timestamp)
        #expect(native.phase.isEmpty && native.momentumPhase.isEmpty)
        #expect(native.windowNumber == 123)
    }

    @Test("60/120Hz 位移守恒、无零帧、AppKit 视图确实移动", arguments: [60.0, 120.0])
    func appKitConsumption(rate: Double) throws {
        // 休眠或无活动显示器时 AppKit 不驱动隐藏窗口的滚动；明确报前置条件失败，
        // 不把环境不可用误报为鼠标算法失败，也不通过强制绘制绕过系统状态。
        var activeDisplays: UInt32 = 0
        try #require(CGGetActiveDisplayList(0, nil, &activeDisplays) == .success && activeDisplays > 0,
                     "AppKit 消费回归需要活动显示器，请唤醒并解锁桌面后执行")
        let harness = Harness()
        defer { harness.runtime.stop() }
        let input = try makeScrollWheelEvent(verticalDelta: 1)
        #expect(harness.send(input) == nil)
        // 第二次输入必须并入同一轨迹。
        #expect(harness.send(input) == nil)
        #expect(harness.send(try makeScrollWheelEvent(verticalDelta: 0)) != nil)
        harness.driver.drain(interval: 1 / rate)
        let events = harness.outputs.read { $0 }
        let native = try events.map { try #require(NSEvent(cgEvent: $0)) }
        #expect(!native.isEmpty)
        #expect(native.allSatisfy { $0.scrollingDeltaY < 0 })
        let total = native.reduce(0.0) { $0 + $1.scrollingDeltaY }
        #expect(abs(total + 183.6) < 1)
        #expect(harness.driver.elapsed <= 0.18 + 1 / rate)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        let before = scroll.contentView.bounds.origin.y
        for event in native { scroll.scrollWheel(with: event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let after = scroll.contentView.bounds.origin.y
        #expect(abs(abs(after - before) - abs(total)) < 1)
        // 原生无 phase 的构造事件确实能被 NSScrollView 消费；这不替代跨进程送达验收。
        #expect(harness.runtime.scrollDiagnostics.output.generatedEvents == events.count)
    }

    @Test("小输入余数跨脉冲保留，反转清旧余量")
    func fractionalPulses() throws {
        let harness = Harness()
        defer { harness.runtime.stop() }
        for _ in 0..<10 {
            let event = try makeScrollWheelEvent(verticalDelta: 1, isContinuous: true)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 1)
            #expect(harness.send(event) == nil)
            harness.driver.drain()
        }
        let total = harness.outputs.read { $0.reduce(0.0) { $0 + (NSEvent(cgEvent: $1)?.scrollingDeltaY ?? 0) } }
        #expect(abs(total + 27) < 1)
        #expect(harness.outputs.read { $0.allSatisfy { ($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) < 0 } })
        harness.outputs.mutate { $0.removeAll() }
        #expect(harness.send(try makeScrollWheelEvent(verticalDelta: -1)) == nil)
        harness.driver.drain()
        #expect(harness.outputs.read { $0.allSatisfy { (NSEvent(cgEvent: $0)?.scrollingDeltaY ?? 0) > 0 } })
    }

    @Test("配置按事件目标匹配，直接输出与降级仍可消费")
    func directAndTargetProfile() throws {
        var settings = MouseEnhancementSettings.defaults
        settings.globalTuning.reverseVertical = false
        var tuning = MouseScrollTuning.defaults
        tuning.smoothEnabled = false
        settings.appProfiles = [MouseAppScrollProfile(displayName: "Target", bundleIdentifier: "target.app", behavior: .custom, tuning: tuning)]
        let harness = Harness(settings: settings, provider: { $0 == 222 ? "target.app" : nil })
        defer { harness.runtime.stop() }
        let event = try makeScrollWheelEvent(verticalDelta: 1, targetProcessIdentifier: 222)
        let output = try #require(harness.send(event))
        #expect(NSEvent(cgEvent: output)?.scrollingDeltaY == -91)
        #expect(output !== event)
        #expect(harness.runtime.scrollDiagnostics.targetBundleIdentifier == "target.app")
        // Control 临时禁用平滑，不能把消费过的修饰键传给应用触发缩放。
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 333)
        event.flags = .maskControl
        let direct = try #require(harness.send(event))
        #expect(NSEvent(cgEvent: direct)?.scrollingDeltaY == 91)
        #expect(!direct.flags.contains(.maskControl))

        let unavailable = Harness(available: false)
        defer { unavailable.runtime.stop() }
        let fallback = try #require(unavailable.send(try makeScrollWheelEvent(verticalDelta: 1)))
        #expect(NSEvent(cgEvent: fallback)?.scrollingDeltaY == -91)
        #expect(unavailable.runtime.lastRuntimeWarning?.contains("降级") == true)
        unavailable.driver.available = true
        #expect(unavailable.send(try makeScrollWheelEvent(verticalDelta: 1)) == nil)
        // 驱动启动尚不等于已恢复；必须产生并提交平滑帧，旧故障才清除。
        #expect(unavailable.runtime.lastRuntimeWarning != nil)
        unavailable.driver.drain()
        #expect(unavailable.runtime.scrollDiagnostics.output.postedFrames > 0)
        #expect(unavailable.runtime.lastRuntimeWarning == nil)
        #expect(unavailable.runtime.lastFailureReason == nil)
        unavailable.driver.available = false
        _ = unavailable.send(try makeScrollWheelEvent(verticalDelta: 1))
        unavailable.runtime.reportConfigurationFailure("保留新的配置错误")
        unavailable.driver.available = true
        _ = unavailable.send(try makeScrollWheelEvent(verticalDelta: 1))
        unavailable.driver.drain()
        #expect(unavailable.runtime.lastRuntimeWarning == "保留新的配置错误")

        // build 18 的真实故障：PID 有效而窗口为 0，禁止吞掉输入后异步投递。
        let missingWindow = try makeScrollWheelEvent(verticalDelta: 1, targetWindowNumber: 0)
        let safe = Harness()
        defer { safe.runtime.stop() }
        let synchronous = try #require(safe.send(missingWindow))
        #expect(NSEvent(cgEvent: synchronous)?.scrollingDeltaY == -91)
        #expect(safe.driver.callback == nil)
        #expect(safe.outputs.read { $0.isEmpty })
        #expect(safe.runtime.scrollDiagnostics.output.directFallbacks == 1)
        #expect(!safe.runtime.scrollDiagnostics.targetWindowAvailable)
        #expect(safe.runtime.lastRuntimeWarning?.contains("窗口标注") == true)
    }

    @Test("真实显示刷新器首次创建或启动失败后可恢复，不靠重启 Host", arguments: [false, true])
    func displayLinkRecovery(failStart: Bool) throws {
        var count: UInt32 = 0
        try #require(CGGetActiveDisplayList(0, nil, &count) == .success && count > 0,
                     "真实 CVDisplayLink 回归需要活动显示器")
        let attempts = LockedTestValue(0)
        let startAttempts = LockedTestValue(0)
        let uptime = LockedTestValue(1.0)
        let frame = DispatchSemaphore(value: 0)
        let driver = DisplayLinkedMouseSmoothScrollFrameDriver(createDisplayLink: {
            let attempt = attempts.mutate { $0 += 1; return $0 }
            if !failStart && attempt == 1 { return nil }
            return DisplayLinkedMouseSmoothScrollFrameDriver.makeDisplayLink()
        }, startDisplayLink: { link in
            let attempt = startAttempts.mutate { $0 += 1; return $0 }
            if failStart && attempt == 1 { return kCVReturnError }
            return CVDisplayLinkStart(link)
        }, uptime: { uptime.read { $0 } })
        defer { driver.stop() }
        #expect(attempts.read { $0 } == 0)
        #expect(!driver.start { _, _ in frame.signal(); return false })
        // 失败期间密集滚动不反复创建系统对象。
        #expect(!driver.start { _, _ in frame.signal(); return false })
        #expect(attempts.read { $0 } == 1)
        #expect(frame.wait(timeout: .now()) == .timedOut)
        uptime.mutate { $0 += 1 }
        #expect(driver.start { _, _ in frame.signal(); return false })
        #expect(attempts.read { $0 } == 2)
        #expect(frame.wait(timeout: .now() + 2) == .success)
    }

    @Test("目标窗口切换、原生输入、停止都取消尾段；待投递任务有界")
    func boundedCancellation() throws {
        let work = LockedTestValue([@Sendable () -> Void]())
        let harness = Harness(delivery: { task in work.mutate { $0.append(task) } })
        defer { harness.runtime.stop() }
        var event = try makeScrollWheelEvent(verticalDelta: 1)
        event.location = CGPoint(x: 10, y: 10)
        _ = harness.send(event)
        harness.driver.drain()
        #expect(work.read { $0.count } == 1)
        #expect(harness.outputs.read { $0.isEmpty })
        // 同一 PID、同一屏幕位置也可能切到另一个重叠窗口，旧尾段不能合入新窗口。
        event = try makeScrollWheelEvent(verticalDelta: 1, targetWindowNumber: 124)
        event.location = CGPoint(x: 10, y: 10)
        _ = harness.send(event)
        harness.driver.drain()
        #expect(work.read { $0.count } == 1)
        work.mutate { $0.removeFirst() }()
        #expect(harness.outputs.read { $0.count } == 1)
        #expect(harness.outputs.read { NSEvent(cgEvent: $0[0])?.scrollingDeltaY } == -91)
        #expect(harness.outputs.read { NSEvent(cgEvent: $0[0])?.windowNumber } == 124)
        harness.outputs.mutate { $0.removeAll() }
        _ = harness.send(event)
        harness.driver.tick()
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        #expect(harness.send(event) === event)
        work.mutate { $0.removeFirst() }()
        #expect(harness.outputs.read { $0.isEmpty })
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        _ = harness.send(event)
        harness.driver.tick()
        harness.runtime.stop()
        work.mutate { $0.removeFirst() }()
        #expect(harness.outputs.read { $0.isEmpty })
        #expect(harness.send(event) === event)
    }

    @Test("后台帧通过生产队列投递，未依赖 MainActor")
    func backgroundDelivery() throws {
        let finished = DispatchSemaphore(value: 0)
        let background = LockedTestValue(false)
        var handler: EventTap.Handler?
        let runtime = MouseAgentRuntime(eventTapFactory: { _, callback in handler = callback; return MockMouseEventTap() },
            smoothEventPoster: { _, _ in background.mutate { $0 = !Thread.isMainThread }; finished.signal() },
            smoothFrameDriver: BackgroundThreadMouseSmoothScrollFrameDriver(), targetBundleIdentifierProvider: { _ in nil })
        defer { runtime.stop() }
        runtime.start(settings: .defaults)
        _ = handler?(try #require(CGEventTapProxy(bitPattern: 1)), try makeScrollWheelEvent(verticalDelta: 1))
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(background.read { $0 })
    }

    @Test("取消等待已开始的投递，显示回调不等待慢消费者")
    nonisolated func cancellationDuringPost() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let count = LockedTestValue(0)
        let driver = ManualScrollFrames(available: true)
        let session = MouseScrollSession(eventPoster: { _, _ in
            count.mutate { $0 += 1 }
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }, frameDriver: driver, eventDeliveryScheduler: MouseSmoothScrollExecution.deliverOnProductionQueue)
        let input = try makeScrollWheelEvent(verticalDelta: 1)
        _ = session.handle(MouseScrollImpulse(verticalDelta: 90, horizontalDelta: 0, responseTimeMs: 180),
                           originalEvent: input, destination: ScrollWheelEventView(event: input).target, smooth: true)
        let callback = try #require(driver.callback)
        #expect(callback(1, 1.0 / 60))
        #expect(entered.wait(timeout: .now() + 1) == .success)
        // 投递尚未结束时，下一次显示回调仍能更新状态并返回。
        #expect(callback(1.02, 1.0 / 60))
        DispatchQueue.global().async { session.cancelPendingEvents(); cancelled.signal() }
        #expect(cancelled.wait(timeout: .now() + 0.03) == .timedOut)
        release.signal()
        #expect(cancelled.wait(timeout: .now() + 1) == .success)
        #expect(!callback(1.04, 1.0 / 60))
        #expect(count.read { $0 } == 1)
    }

    @Test("合成事件透传，不递归；两个会话互不影响")
    func isolation() throws {
        let first = Harness(), second = Harness()
        defer { first.runtime.stop(); second.runtime.stop() }
        let event = try makeScrollWheelEvent(verticalDelta: 1)
        event.setIntegerValueField(.eventSourceUserData, value: MouseScrollEventOrigin.syntheticMarker)
        #expect(first.send(event) === event)
        #expect(first.runtime.scrollDiagnostics.wheelInputs == 0)
        let physical = try makeScrollWheelEvent(verticalDelta: 1)
        _ = first.send(physical)
        _ = second.send(physical)
        first.runtime.stop()
        second.driver.drain()
        #expect(second.outputs.read { !$0.isEmpty })
        #expect(first.outputs.read { $0.isEmpty })
    }
}

@MainActor
private final class Harness {
    let driver: ManualScrollFrames
    let outputs = LockedTestValue([CGEvent]())
    let runtime: MouseAgentRuntime
    private let handler: EventTap.Handler
    init(settings: MouseEnhancementSettings = .defaults, available: Bool = true,
         provider: @escaping (pid_t) -> String? = { _ in nil },
         delivery: @escaping MouseSmoothEventDeliveryScheduler = { $0() }) {
        var captured: EventTap.Handler?
        driver = ManualScrollFrames(available: available)
        let output = outputs
        runtime = MouseAgentRuntime(eventTapFactory: { _, callback in captured = callback; return MockMouseEventTap() },
            smoothEventPoster: { event, _ in output.mutate { $0.append(event) } }, smoothFrameDriver: driver,
            smoothEventDeliveryScheduler: delivery, targetBundleIdentifierProvider: provider)
        runtime.start(settings: settings)
        handler = captured!
    }
    func send(_ event: CGEvent) -> CGEvent? { handler(CGEventTapProxy(bitPattern: 1)!, event) }
}

private final class ManualScrollFrames: MouseSmoothScrollFrameDriving, @unchecked Sendable {
    var available: Bool
    var callback: (@Sendable (CFTimeInterval, CFTimeInterval) -> Bool)?
    var elapsed = 0.0
    init(available: Bool) { self.available = available }
    func start(frameHandler: @escaping @Sendable (CFTimeInterval, CFTimeInterval) -> Bool) -> Bool {
        callback = available ? frameHandler : nil
        return available
    }
    func stop() { callback = nil }
    func tick(interval: Double = 1.0 / 120) {
        elapsed += interval
        if callback?(elapsed, interval) == false { callback = nil }
    }
    func drain(interval: Double = 1.0 / 120) {
        var count = 0
        while callback != nil && count < 1000 { tick(interval: interval); count += 1 }
        #expect(count < 1000)
    }
}

private func makeScrollWheelEvent(
    verticalDelta: Int32,
    horizontalDelta: Int32 = 0,
    isContinuous: Bool = false,
    targetProcessIdentifier: pid_t = getpid(),
    targetWindowNumber: Int = 123
) throws -> CGEvent {
    let pixelTemplate = try #require(CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 2,
        wheel1: verticalDelta,
        wheel2: horizontalDelta,
        wheel3: 0
    ), "无法构造滚轮 CGEvent")
    // NSEvent 公共构造器保存窗口上下文；单有 setTargetPID 的事件不能模拟已标注的系统输入。
    let event = try #require(NSEvent.mouseEvent(with: .otherMouseDown, location: CGPoint(x: 100, y: 100),
                                        modifierFlags: [], timestamp: 1, windowNumber: targetWindowNumber,
                                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0)?.cgEvent, "无法构造带窗口标注的事件")
    event.type = .scrollWheel
    for field: CGEventField in [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
        event.setIntegerValueField(field, value: pixelTemplate.getIntegerValueField(field))
    }
    for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
        event.setDoubleValueField(field, value: pixelTemplate.getDoubleValueField(field))
    }
    event.setIntegerValueField(CGEventField.scrollWheelEventDeltaAxis1, value: Int64(verticalDelta))
    event.setIntegerValueField(CGEventField.scrollWheelEventDeltaAxis2, value: Int64(horizontalDelta))
    event.setIntegerValueField(CGEventField.scrollWheelEventIsContinuous, value: isContinuous ? 1 : 0)
    event.setIntegerValueField(CGEventField.eventTargetUnixProcessID, value: Int64(targetProcessIdentifier))
    event.location = CGPoint(x: 100, y: 100)
    // 测试事件不能继承系统当前按键状态，否则残留的 Control 会绕过平滑滚动。
    event.flags = []
    return event
}

private final class MockMouseEventTap: EventTapping {
    var onStateChange: ((EventTapStateChange) -> Void)?
    var isEnabled = true
    func enable() -> Bool { isEnabled = true; return true }
    func invalidate() { isEnabled = false }
}

/// 模拟 CVDisplayLink 的真实线程语义：帧回调必须从非主队列进入运行时。
private final class BackgroundThreadMouseSmoothScrollFrameDriver: MouseSmoothScrollFrameDriving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.archalo.arckit.tests.mouse-display-link")

    func start(frameHandler: @escaping @Sendable (CFTimeInterval, CFTimeInterval) -> Bool) -> Bool {
        queue.async {
            _ = frameHandler(10, 1.0 / 60.0)
        }
        return true
    }

    func stop() {}
}

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(storage)
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
