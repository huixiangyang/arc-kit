@testable import ArcKitWindowRuntime
import ArcKitWindow
import ArcKitPlatform
import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@Suite("窗口场景固定执行与真实撤销")
@MainActor
struct WindowSceneRuntimeTests {
    @Test("批次固定原窗口，回读后才提供撤销，焦点只恢复一次")
    func fixedBatchAndUndo() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let inventory = try await runtime.inventory { true }
        let scene = try fixture.scene(inventory)
        let original = fixture.frames
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(report.items.map(\.status) == [.applied, .applied])
        #expect(fixture.writes == [1, 2])
        #expect(fixture.focusWrites == [1])
        #expect(fixture.frontmostQueries == 0)
        let undo = try #require(report.undoToken)
        let result = try await runtime.undo(undo, settings: .defaults) { true }
        #expect(result.items.allSatisfy { $0.status.isSuccess })
        #expect(result.undoToken == nil)
        #expect(fixture.frames == original)
        await #expect(throws: WindowSceneRuntimeError.self) { try await runtime.undo(undo, settings: .defaults) { true } }
    }

    @Test("应用限制尺寸必须报告constrained，撤销不精确也不能成功")
    func constrainedUndoIsNotSuccess() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let scene = try fixture.scene(await runtime.inventory { true })
        fixture.widthOffset = 30
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(report.items.allSatisfy { $0.status == .constrained })
        #expect(report.successfulCount == 0)
        let token = try #require(report.undoToken)
        let undo = try await runtime.undo(token, settings: .defaults) { true }
        #expect(undo.items.allSatisfy { $0.status == .constrained })
        #expect(undo.undoToken == token)
    }

    @Test("取消保留已移动窗口的撤销而跳过剩余窗口")
    func cancellationRetainsPartialUndo() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let scene = try fixture.scene(await runtime.inventory { true })
        let report = await runtime.apply(scene, settings: .defaults) { fixture.writes.isEmpty }
        #expect(fixture.writes == [1])
        #expect(report.items.map(\.status) == [.unavailable, .unavailable])
        let token = try #require(report.undoToken)
        let undo = try await runtime.undo(token, settings: .defaults) { true }
        #expect(undo.items.count == 1)
        #expect(undo.items.first?.status == .applied)
    }

    @Test("配置禁用中断批次，重新启用后仍能撤销已移动窗口")
    func configurationChangePreservesUndo() async throws {
        let fixture = SceneAXFixture()
        let inventoryRuntime = fixture.sceneRuntime()
        let scene = try fixture.scene(await inventoryRuntime.inventory { true })
        let runtime = WindowAgentRuntime(accessibilityClient: fixture, accessibilityTrusted: { true },
                                         sceneDisplaysProvider: { [fixture.display] })
        var settings = WindowManagementSettings.defaults
        settings.scenes = [scene]
        await runtime.start(settings: settings)
        fixture.afterWrite = { _ in runtime.stop() }
        let report = try await runtime.applyScene(scene.id)
        #expect(report.items.map(\.status) == [.unavailable, .unavailable])
        #expect(runtime.state == .stopped)
        #expect(runtime.lastSceneResult == report)
        fixture.afterWrite = nil
        await runtime.start(settings: settings)
        let undo = try await runtime.undoScene(#require(report.undoToken), deadline: Date().addingTimeInterval(5))
        #expect(undo.items.count == 1)
        #expect(undo.items[0].status.isSuccess)
    }

    @Test("已提交窗口暂离桌面再回来保留身份，新的同名窗口不顶替")
    func pinnedWindowReturnsToDesktop() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let first = try await runtime.inventory { true }
        let scene = try fixture.scene(first)
        runtime.updateScenes([scene])
        fixture.hiddenIDs.insert(1)
        _ = try await runtime.inventory { true }
        fixture.hiddenIDs = []
        let returned = try await runtime.inventory { true }
        #expect(returned.candidates[0].id == first.candidates[0].id)
        fixture.targets[0].element = NSObject()
        let replaced = try await runtime.inventory { true }
        #expect(replaced.candidates[0].id != first.candidates[0].id)
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(report.items[0].status == .missingWindow)
        #expect(fixture.writes == [2])
    }

    @Test("同一AX引用刷新和标题变化保持令牌，关闭目标不能写到其他窗口")
    func stableCaptureAndClosedWindow() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let inventory = try await runtime.inventory { true }
        let scene = try fixture.scene(inventory)
        fixture.targets[0].restoreKey.title = "renamed"
        let refreshed = try await runtime.inventory { true }
        #expect(refreshed.candidates[0].sessionHint == inventory.candidates[0].sessionHint)
        fixture.targets.remove(at: 0)
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(report.items[0].status == .missingWindow)
        #expect(fixture.writes == [2])
    }

    @Test("业务缺失不破坏服务状态，缺屏与排除规则不写入")
    func missingDisplayAndExcludedApp() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        var scene = try fixture.scene(await runtime.inventory { true })
        scene.displays.append(.init(id: "missing", name: "Unplugged", visibleFrame: fixture.display.visibleFrame))
        scene.entries[0].displayID = "missing"
        var settings = WindowManagementSettings.defaults
        settings.excludedApplications = [.init(displayName: "Scene", bundleIdentifier: "test.scene")]
        let report = await runtime.apply(scene, settings: settings) { true }
        #expect(report.items.map(\.status) == [.missingDisplay, .excludedApplication])
        #expect(fixture.writes.isEmpty)
        #expect(report.undoToken == nil)
    }

    @Test("计划后窗口离开当前桌面与屏幕几何变化都不能继续搬动")
    func revalidateDesktopAndDisplay() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let scene = try fixture.scene(await runtime.inventory { true })
        fixture.afterWrite = { number in if number == 1 { fixture.hiddenIDs.insert(2) } }
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(fixture.writes == [1])
        #expect(report.items[1].status == .failed)
        fixture.hiddenIDs = []
        fixture.afterWrite = nil
        fixture.display.visibleFrame.size.width = 1200
        let undo = try await runtime.undo(#require(report.undoToken), settings: .defaults) { true }
        #expect(fixture.writes == [1])
        #expect(undo.items[0].status == .unavailable)
        #expect(undo.undoToken != nil)
    }

    @Test("已写入后回读失败仍保留恢复点，不报告成功")
    func writeThenUnreadableRetainsRecovery() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        let scene = try fixture.scene(await runtime.inventory { true })
        fixture.afterWrite = { _ in fixture.failReads = true }
        let report = await runtime.apply(scene, settings: .defaults) { true }
        #expect(report.items[0].status == .failed)
        #expect(report.undoToken != nil)
        fixture.afterWrite = nil
        fixture.failReads = false
        let undo = try await runtime.undo(#require(report.undoToken), settings: .defaults) { true }
        #expect(undo.items[0].status.isSuccess)
    }

    @Test("IPC场景操作严格拒绝多余载荷和错误回执")
    func strictSceneIPC() throws {
        let id = UUID()
        try WindowAgentRequest(operation: .applyScene, sceneID: id).validate()
        #expect(throws: RuntimeAgentIPCError.self) { try WindowAgentRequest(operation: .applyScene).validate() }
        #expect(throws: RuntimeAgentIPCError.self) { try WindowAgentRequest(operation: .applyScene, action: .fill, sceneID: id).validate() }
        #expect(throws: RuntimeAgentIPCError.self) { try WindowAgentRequest(operation: .undoScene, sceneID: id, undoToken: id).validate() }
        #expect(throws: RuntimeAgentIPCError.self) { try WindowAgentRequest(operation: .fetchState, sceneID: id).validate() }
        let state = WindowAgentRuntimeSnapshot(lifecycle: .running, processID: 1, launchID: id,
                                              accessibilityTrusted: true, accessibilityOperational: true)
        #expect(throws: RuntimeAgentIPCError.self) { try WindowAgentReply(requestID: id, state: state).validate(operation: .applyScene) }
    }

    @Test("场景热键与布局冲突均拒绝，注册失败可见，停止真正注销")
    func sceneShortcutRegistration() async throws {
        let fixture = SceneAXFixture()
        let runtime = fixture.sceneRuntime()
        var scene = try fixture.scene(await runtime.inventory { true })
        scene.shortcut = .init(keyCode: 123, keyEquivalent: "←")
        let registrar = SceneHotKeyRegistrar()
        let hotkeys = WindowAgentHotKeyRuntime(registrar: registrar, accessibilityTrusted: { true }, registrationRetryDelays: [])
        let windowRuntime = WindowAgentRuntime(accessibilityClient: fixture, accessibilityTrusted: { true })
        var settings = WindowManagementSettings.defaults
        settings.bindings = [.init(action: .leftHalf, keyCode: 123, keyEquivalent: "←")]
        settings.scenes = [scene]
        hotkeys.start(settings: settings, windowService: windowRuntime)
        #expect(hotkeys.sceneFailures[scene.id] != nil)
        #expect(hotkeys.duplicateBindings.count == 1)
        #expect(registrar.registered.isEmpty)
        settings.bindings = []
        registrar.reject = true
        hotkeys.start(settings: settings, windowService: windowRuntime)
        #expect(hotkeys.sceneFailures[scene.id] != nil)
        registrar.reject = false
        hotkeys.stop()
        hotkeys.start(settings: settings, windowService: windowRuntime)
        #expect(hotkeys.sceneFailures.isEmpty)
        #expect(hotkeys.registeredCount == 1)
        hotkeys.stop()
        #expect(registrar.unregistered.count == 1)
        #expect(hotkeys.registeredCount == 0)
    }
}

@MainActor
private final class SceneAXFixture: WindowAccessibilityClient {
    var targets: [WindowActionTarget] = [1, 2].map { (number: Int) in
        WindowActionTarget(element: NSObject(), restoreKey: .init(pid: 901, windowNumber: number,
            title: "window\(number)", role: "AXWindow", subrole: "AXStandardWindow"), pid: 901, bundleIdentifier: "test.scene")
    }
    var frames: [Int: CGRect] = [1: .init(x: 100, y: 100, width: 300, height: 300), 2: .init(x: 200, y: 200, width: 300, height: 300)]
    var display = WindowSceneDisplay(id: "display-one", name: "Display", visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800))
    var writes: [Int] = []
    var focusWrites: [Int] = []
    var frontmostQueries = 0
    var widthOffset: CGFloat = 0
    var hiddenIDs: Set<Int> = []
    var failReads = false
    var afterWrite: ((Int) -> Void)?
    func sceneRuntime() -> WindowSceneRuntime { .init(client: self, displaysProvider: { [self.display] }) }
    func scene(_ inventory: WindowSceneInventory) throws -> WindowScene {
        var entries = try inventory.candidates.map { try WindowSceneEntry.capture(candidate: $0, display: display) }
        entries[0].normalizedFrame = .init(x: 0, y: 0, width: 0.5, height: 1)
        entries[1].normalizedFrame = .init(x: 0.5, y: 0, width: 0.5, height: 1)
        return .init(name: "Development", displays: [display], entries: entries, focusEntryID: entries[0].id)
    }
    func sceneWindows(isValid: @MainActor () -> Bool) async throws -> [WindowSceneAXWindow] {
        targets.filter { !hiddenIDs.contains($0.restoreKey.windowNumber!) }.map { .init(target: $0, applicationName: "Scene", applicationLaunchDate: Date(timeIntervalSince1970: 1)) }
    }
    func frontmostApplication() -> AppConfigurationCandidate? { frontmostQueries += 1; return nil }
    func isApplicationTerminated(pid: pid_t) -> Bool { false }
    func windowTarget(for pid: pid_t, bundleIdentifier: String?) async throws -> WindowActionTarget? { nil }
    func windowTarget(at point: CGPoint) async -> WindowHitTestTarget? { nil }
    func validateWindowAdjustable(_ target: WindowActionTarget) async throws {}
    func validateSceneWindowVisible(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws {
        guard !hiddenIDs.contains(target.restoreKey.windowNumber!), targets.contains(where: { CFEqual($0.element, target.element) }) else { throw WindowManagementExecutionError.unreadableWindow }
    }
    func isWindowFullScreen(_ target: WindowActionTarget) async throws -> Bool { false }
    func setWindowFullScreen(_ enabled: Bool, for target: WindowActionTarget) async throws {}
    func frame(of target: WindowActionTarget) async throws -> CGRect {
        guard !failReads, let number = target.restoreKey.windowNumber, targets.contains(where: { $0.restoreKey.windowNumber == number }),
              let frame = frames[number] else { throw WindowManagementExecutionError.unreadableWindow }
        return frame
    }
    func setFrame(_ frame: CGRect, for target: WindowActionTarget) async throws {
        let number = target.restoreKey.windowNumber!
        var actual = frame
        actual.size.width += widthOffset
        frames[number] = actual
        writes.append(number)
        afterWrite?(number)
    }
    func focusWindow(_ target: WindowActionTarget, isValid: @MainActor () -> Bool) async throws { focusWrites.append(target.restoreKey.windowNumber!) }
}

@MainActor
private final class SceneHotKeyRegistrar: GlobalHotKeyRegistering {
    var reject = false
    var registered: [UInt32] = []
    var unregistered: [EventHotKeyRef] = []
    func installEventHandler(owner: WindowAgentHotKeyRuntime) -> EventHandlerRef? { OpaquePointer(bitPattern: 1) }
    func removeEventHandler(_ reference: EventHandlerRef) {}
    func register(keyCode: UInt16, modifiers: WindowHotKeyModifier, identifier: UInt32, signature: OSType) -> EventHotKeyRef? {
        guard !reject else { return nil }
        registered.append(identifier)
        return OpaquePointer(bitPattern: Int(identifier) + 1)
    }
    func unregister(_ reference: EventHotKeyRef) { unregistered.append(reference) }
}
