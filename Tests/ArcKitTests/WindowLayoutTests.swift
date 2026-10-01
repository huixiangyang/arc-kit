@testable import ArcKitApplication
@testable import ArcKitWindowRuntime
import ArcKitPlatform
import ArcKitWindow
import AppKit
import Foundation
import Testing

@Suite("窗口布局与快捷键配置")
struct WindowLayoutTests {
    @Test("跨屏切换焦点后仍执行打开面板时的具体窗口")
    @MainActor
    func capturedWindowSurvivesFocusChanges() async throws {
        let client = WindowTargetFixture()
        let runtime = client.runtime()
        await runtime.start(settings: .defaults)
        let firstCapture = try await runtime.captureWindowTarget()
        let first = try #require(firstCapture.targetID)
        client.focused = client.second
        let secondCapture = try await runtime.captureWindowTarget()
        let second = try #require(secondCapture.targetID)
        client.frontmost = .init(displayName: "Arc Kit", bundleIdentifier: ArcKitConstants.appBundleIdentifier, processIdentifier: 200)
        let queries = client.queries
        #expect(await runtime.perform(.leftHalf, capturedTargetID: first).succeeded)
        #expect(await runtime.perform(.rightHalf, capturedTargetID: second).succeeded)
        #expect(client.writes == [1, 2])
        #expect(client.queries == queries)
        #expect(client.frames[1]?.minX == -1920)
        #expect(client.frames[2]?.maxX == 3360)
    }

    @Test("点击来源跨 XPC 保持固定，不能被后来激活的应用或自身窗口替代")
    @MainActor
    func captureUsesRequestedApplication() async throws {
        let client = WindowTargetFixture()
        let runtime = client.runtime()
        await runtime.start(settings: .defaults)
        let clicked = try #require(client.frontmost)
        client.frontmost = .init(displayName: "Other", bundleIdentifier: "test.other", processIdentifier: 300)
        let targetCapture = try await runtime.captureWindowTarget(application: clicked)
        let target = try #require(targetCapture.targetID)
        #expect(client.requestedPIDs == [100])
        #expect(await runtime.perform(.leftHalf, capturedTargetID: target).succeeded)
        #expect(client.writes == [1])

        client.terminatedPIDs.insert(100)
        let gone = try await runtime.captureWindowTarget(application: clicked)
        let own = try await runtime.captureWindowTarget(application: .init(displayName: "Arc Kit", bundleIdentifier: ArcKitConstants.appBundleIdentifier, processIdentifier: 200))
        #expect(gone.targetID == nil && gone.failureMessage != nil)
        #expect(own.targetID == nil && own.failureMessage != nil)
        #expect(client.requestedPIDs == [100])
        #expect(client.writes == [1])
    }

    @Test("缺失、关闭和失效的捕获拒绝执行，不改选当前窗口或设置窗口")
    @MainActor
    func failedCaptureNeverRetargets() async throws {
        let client = WindowTargetFixture()
        let runtime = client.runtime()
        await runtime.start(settings: .defaults)
        client.focused = nil
        let empty = try await runtime.captureWindowTarget()
        client.focused = client.first
        #expect(empty.targetID == nil && empty.failureMessage != nil)
        let panel = MenuBarPanelState()
        panel.windowActionsAvailable = true
        let firstCapture = panel.windowTarget.begin()
        let acceptedEmpty = panel.windowTarget.complete(empty, for: firstCapture)
        #expect(acceptedEmpty)
        #expect(!panel.canPerformWindowActions)
        client.captureError = .unsupportedWindow(.nonWindow)
        let rejected = try await runtime.captureWindowTarget()
        #expect(rejected == .unavailable(WindowManagementExecutionError.unsupportedWindow(.nonWindow).localizedDescription))
        let rejectedCapture = panel.windowTarget.begin()
        let acceptedOld = panel.windowTarget.complete(.ready(UUID()), for: firstCapture)
        #expect(!acceptedOld)
        let acceptedRejection = panel.windowTarget.complete(rejected, for: rejectedCapture)
        #expect(acceptedRejection)
        let acceptedDuplicate = panel.windowTarget.complete(.ready(UUID()), for: rejectedCapture)
        #expect(!acceptedDuplicate)
        #expect(!panel.canPerformWindowActions && panel.windowTarget.failureMessage == rejected.failureMessage)
        #expect(runtime.lastResult == nil) // 捕获拒绝不弹执行失败 HUD，也不污染服务健康。
        client.captureError = nil
        #expect(await !runtime.perform(.fill, capturedTargetID: UUID()).succeeded)
        let closedCapture = try await runtime.captureWindowTarget()
        let closed = try #require(closedCapture.targetID)
        let validCapture = panel.windowTarget.begin()
        let acceptedValid = panel.windowTarget.complete(closedCapture, for: validCapture)
        #expect(acceptedValid)
        #expect(panel.canPerformWindowActions)
        let cancelled = panel.windowTarget.begin()
        panel.windowTarget.reset()
        let acceptedCancelled = panel.windowTarget.complete(closedCapture, for: cancelled)
        #expect(!acceptedCancelled)
        #expect(!panel.canPerformWindowActions)
        client.frames[1] = nil
        client.focused = client.second
        #expect(await !runtime.perform(.fill, capturedTargetID: closed).succeeded)
        let staleCapture = try await runtime.captureWindowTarget()
        let stale = try #require(staleCapture.targetID)
        await runtime.start(settings: .defaults)
        #expect(await !runtime.perform(.fill, capturedTargetID: stale).succeeded)
        var ownWindow = client.second
        ownWindow.bundleIdentifier = ArcKitConstants.appBundleIdentifier
        #expect(await !runtime.perform(.fill, preferredTarget: ownWindow).succeeded)
        #expect(client.writes.isEmpty)

        var store = WindowTargetStore()
        let now = Date()
        let oldest = store.insert(client.first, now: now)
        for offset in 1...8 { _ = store.insert(client.second, now: now.addingTimeInterval(Double(offset))) }
        let evicted = store.target(for: oldest, now: now.addingTimeInterval(8))
        #expect(evicted == nil)
        let expiring = store.insert(client.first, now: now.addingTimeInterval(9))
        let alive = store.target(for: expiring, now: now.addingTimeInterval(128))
        #expect(alive?.restoreKey == client.first.restoreKey)
        let expired = store.target(for: expiring, now: now.addingTimeInterval(129))
        #expect(expired == nil)
    }

    @Test("菜单代理激活不改变窗口来源；真实前台 KVO 同时驱动来源和关闭判断")
    @MainActor
    func menuForegroundObservation() throws {
        let workspace = MenuWorkspaceFixture()
        let browser = MenuApplicationFixture(pid: 10, bundle: "test.browser")
        let own = MenuApplicationFixture(pid: 20, bundle: ArcKitConstants.appBundleIdentifier)
        workspace.change(to: browser)
        let source = MenuBarClickSource()
        defer { source.stop() }
        var changes: [pid_t?] = []
        source.onForegroundChange = { changes.append($0) }
        source.observeForeground(in: workspace)
        let handler = source.makeHandler()
        let point = CGPoint(x: 1100, y: 12)
        let bar = CGRect(x: 0, y: 0, width: 1920, height: 24)
        func click() throws -> pid_t? {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                            mouseCursorPosition: point, mouseButton: .left))
            // 未投递的合成事件时间戳为零；补充本次输入时间，不向系统发送。
            event.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
            _ = handler(OpaquePointer(bitPattern: 1)!, event)
            return source.consume(at: point, now: ProcessInfo.processInfo.systemUptime,
                                  menuBarFrames: [bar])?.application.processIdentifier
        }
        // 复现代理通知 Arc Kit 激活、实际键盘接收者仍是浏览器；不发送真实系统输入。
        workspace.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: workspace,
                                          userInfo: [NSWorkspace.applicationUserInfoKey: own])
        #expect(try click() == 10)
        #expect(changes == [10])
        workspace.change(to: own)
        #expect(try click() == 20) // 设置窗口确实在前台时保留自身，交由 Host 拒绝，不回退浏览器。
        workspace.change(to: nil)
        #expect(try click() == nil)
        #expect(changes == [10, 20, nil])
        source.stop()
        workspace.change(to: browser)
        #expect(try click() == nil)
        #expect(changes == [10, 20, nil])
    }

    @Test("菜单只消费点击前来源，拒绝过期、移位及非菜单栏点击")
    @MainActor
    func menuClickOrigin() async {
        let source = MenuBarClickSource()
        let handler = source.makeHandler()
        let app = AppConfigurationCandidate(displayName: "Browser", bundleIdentifier: "test.browser", processIdentifier: 10)
        let own = AppConfigurationCandidate(displayName: "Arc Kit", bundleIdentifier: ArcKitConstants.appBundleIdentifier, processIdentifier: 20)
        let other = AppConfigurationCandidate(displayName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 30)
        let point = CGPoint(x: 1100, y: -1070)
        let bar = CGRect(x: 0, y: -1080, width: 1920, height: 30)
        // 在真实后台线程调用生产回调，覆盖 Swift 6 运行时隔离检查；事件不投递到系统。
        let deliver: @Sendable (TimeInterval) async -> Bool = { timestamp in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    guard !Thread.isMainThread,
                          let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                              mouseCursorPosition: point, mouseButton: .left) else {
                        continuation.resume(returning: false)
                        return
                    }
                    event.timestamp = UInt64(timestamp * 1_000_000_000)
                    continuation.resume(returning: handler(OpaquePointer(bitPattern: 1)!, event) === event)
                }
            }
        }
        #expect(await deliver(98))
        #expect(source.consume(at: point, now: 98.1, menuBarFrames: [bar]) == nil)
        source.recordForeground(app, at: 99)
        // 菜单转发先激活自身、回调稍后到达，也必须用按下时的浏览器。
        source.recordForeground(own, at: 100.05)
        #expect(await deliver(100))
        source.recordForeground(other, at: 100.1)
        #expect(await deliver(100))
        #expect(source.consume(at: point, now: 100.2, menuBarFrames: [bar])?.application == app)
        #expect(await deliver(100))
        #expect(source.consume(at: point, now: 100.2, menuBarFrames: [bar]) == nil)
        // 真正的新点击使用新的应用，不能永久保留第一次或“最近外部”来源。
        #expect(await deliver(100.3))
        #expect(await deliver(100)) // 旧输入迟到也不能覆盖本次点击。
        #expect(source.consume(at: point, now: 100.4, menuBarFrames: [bar])?.application == other)
        source.recordForeground(own, at: 101)
        #expect(await deliver(101.1))
        #expect(source.consume(at: point, now: 101.2, menuBarFrames: [bar])?.application == own)
        source.recordForeground(nil, at: 101.3)
        #expect(await deliver(101.4))
        #expect(source.consume(at: point, now: 101.5, menuBarFrames: [bar]) == nil)
        source.stop()
        #expect(await deliver(102))
        #expect(source.consume(at: point, now: 102.1, menuBarFrames: [bar]) == nil)
        let origin = MenuBarClickSource.Origin(application: app, location: point, timestamp: 100)
        #expect(MenuBarClickSource.match(origin, at: point, now: 100.1, menuBarFrames: [bar])?.application == app)
        #expect(MenuBarClickSource.match(origin, at: point, now: 102, menuBarFrames: [bar]) == nil)
        #expect(MenuBarClickSource.match(origin, at: point, now: 99, menuBarFrames: [bar]) == nil)
        #expect(MenuBarClickSource.match(origin, at: .zero, now: 100.1, menuBarFrames: [bar]) == nil)
        #expect(MenuBarClickSource.match(origin, at: point, now: 100.1, menuBarFrames: [.zero]) == nil)
        #expect(MenuBarClickSource.match(nil, at: point, now: 100.1, menuBarFrames: [bar]) == nil)
    }
    @Test("台前调度保留左侧空间，适配屏幕原点与窗口间距")
    func stageManagerFrame() throws {
        let engine = WindowLayoutEngine()
        let cases: [(screen: CGRect, gap: Double, expected: CGRect)] = [
            (.init(x: 0, y: 24, width: 1440, height: 876), 0,
             .init(x: 216, y: 24, width: 1224, height: 876)),
            (.init(x: -1920, y: -300, width: 1920, height: 1080), 12,
             .init(x: -1620, y: -288, width: 1608, height: 1056)),
            (.init(x: 1440, y: 30, width: 3440, height: 1410), 8,
             .init(x: 1964, y: 38, width: 2908, height: 1394)),
        ]
        for sample in cases {
            let original = CGRect(x: sample.screen.minX + 100, y: sample.screen.minY + 100, width: 600, height: 400)
            var input = WindowLayoutInput(
                action: .stageManager, currentFrame: original,
                currentScreenVisibleFrame: sample.screen,
                allScreenVisibleFrames: [sample.screen], gap: sample.gap
            )
            let frame = try engine.frame(for: input)
            #expect(abs(frame.minX - sample.expected.minX) < 0.001)
            #expect(abs(frame.minY - sample.expected.minY) < 0.001)
            #expect(abs(frame.width - sample.expected.width) < 0.001)
            #expect(abs(frame.height - sample.expected.height) < 0.001)
            #expect(sample.screen.contains(frame))
            input.action = .restore
            input.currentFrame = frame
            input.previousFrame = original
            #expect(try engine.frame(for: input) == original)
        }
    }

    @Test("新增布局不使已保存快捷键失效，首次录制可持久化且拒绝重复动作")
    func optionalLayoutBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SettingsRepository(directoryURL: directory)
        var settings = AppSettings.defaults
        settings.windowManagement.windowGap = 12
        settings.windowManagement.bindings[0].isEnabled = false
        #expect(settings.windowManagement.binding(for: .stageManager) == nil)
        try repository.save(settings)
        #expect(try repository.load() == settings)

        let existing = settings.windowManagement.bindings
        var newBinding = WindowHotKeyBinding(action: .stageManager, keyCode: 1, keyEquivalent: "S")
        settings.windowManagement.setBinding(newBinding)
        newBinding.modifiers = [.command, .option]
        settings.windowManagement.setBinding(newBinding)
        try repository.save(settings)
        let loaded = try repository.load()
        #expect(loaded == settings)
        #expect(loaded.windowManagement.bindings.filter { $0.action != .stageManager } == existing)
        #expect(loaded.windowManagement.hotKeyRegistrationPlan().validBindings.contains(newBinding))

        var duplicate = settings.windowManagement
        duplicate.bindings.append(newBinding)
        let data = try JSONEncoder().encode(duplicate)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WindowManagementSettings.self, from: data) }
    }
}

private final class MenuApplicationFixture: NSRunningApplication, @unchecked Sendable {
    private let pid: pid_t
    private let bundle: String
    init(pid: pid_t, bundle: String) { self.pid = pid; self.bundle = bundle; super.init() }
    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { bundle }
    override var localizedName: String? { bundle }
}

private final class MenuWorkspaceFixture: NSWorkspace {
    private var foreground: NSRunningApplication?
    override var frontmostApplication: NSRunningApplication? { foreground }
    func change(to application: NSRunningApplication?) {
        willChangeValue(forKey: "frontmostApplication")
        foreground = application
        didChangeValue(forKey: "frontmostApplication")
    }
}

/// 只替换系统 AX 边界，捕获、执行、屏幕选择和失效处理都运行生产实现。
@MainActor
private final class WindowTargetFixture: WindowAccessibilityClient {
    let first = WindowActionTarget(element: NSObject(), restoreKey: .init(pid: 100, windowNumber: 1, title: "one", role: "AXWindow", subrole: "AXStandardWindow"), pid: 100, bundleIdentifier: "test.editor")
    let second = WindowActionTarget(element: NSObject(), restoreKey: .init(pid: 100, windowNumber: 2, title: "two", role: "AXWindow", subrole: "AXStandardWindow"), pid: 100, bundleIdentifier: "test.editor")
    var frontmost: AppConfigurationCandidate? = .init(displayName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 100)
    lazy var focused: WindowActionTarget? = first
    var frames: [Int: CGRect] = [1: .init(x: -1800, y: 80, width: 600, height: 400), 2: .init(x: 1600, y: 60, width: 700, height: 500)]
    var writes: [Int] = []
    var queries = 0
    var captureError: WindowManagementExecutionError?
    var requestedPIDs: [pid_t] = []
    var terminatedPIDs: Set<pid_t> = []
    func runtime() -> WindowAgentRuntime {
        WindowAgentRuntime(accessibilityClient: self, accessibilityTrusted: { true }, screenVisibleFramesProvider: {
            [.init(x: -1920, y: 0, width: 1920, height: 1080), .init(x: 0, y: 0, width: 1440, height: 900), .init(x: 1440, y: 0, width: 1920, height: 1080)]
        })
    }
    func frontmostApplication() -> AppConfigurationCandidate? { frontmost }
    func isApplicationTerminated(pid: pid_t) -> Bool { terminatedPIDs.contains(pid) }
    func windowTarget(for pid: pid_t, bundleIdentifier: String?) async throws -> WindowActionTarget? {
        queries += 1
        requestedPIDs.append(pid)
        if let captureError { throw captureError }
        return focused?.pid == pid ? focused : nil
    }
    func windowTarget(at point: CGPoint) async -> WindowHitTestTarget? { nil }
    func validateWindowAdjustable(_ target: WindowActionTarget) async throws {}
    func isWindowFullScreen(_ target: WindowActionTarget) async throws -> Bool { false }
    func setWindowFullScreen(_ enabled: Bool, for target: WindowActionTarget) async throws {}
    func frame(of target: WindowActionTarget) async throws -> CGRect {
        guard let id = target.restoreKey.windowNumber, let frame = frames[id] else { throw WindowManagementExecutionError.unreadableWindow }
        return frame
    }
    func setFrame(_ frame: CGRect, for target: WindowActionTarget) async throws {
        let id = target.restoreKey.windowNumber!
        frames[id] = frame
        writes.append(id)
    }
}
