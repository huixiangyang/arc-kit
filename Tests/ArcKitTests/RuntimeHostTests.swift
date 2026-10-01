@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import ArcKitWindow
import ArcKitMouse
import Foundation
import Testing

@MainActor
private final class HostSystemFixture: RuntimeHostSystem {
    var isInstalled = true
    var isRunning = false
    var saved: [RuntimeHostSession] = []
    var registrations = 0
    var removals = 0
    var unregistrations = 0
    var restorations = 0
    var mainAppRemovals = 0
    var stopped = true
    var failSave = false
    func save(_ session: RuntimeHostSession) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
        saved.append(session)
    }
    func removeSession() throws { removals += 1 }
    func ensureRegistered() throws { registrations += 1 }
    func unregisterHost() throws { unregistrations += 1 }
    func waitUntilStopped() async -> Bool { stopped }
    func registrationSnapshot() -> RuntimeServiceRegistrationSnapshot {
        .init(mainAppShouldRestore: true, hostShouldRestore: true)
    }
    func unregisterMainApp() throws { mainAppRemovals += 1 }
    func restoreRegistration(_ snapshot: RuntimeServiceRegistrationSnapshot) throws { restorations += 1 }
    func invalidateFinderSnapshot() {}
}

@MainActor
private final class HostTransportFixture: RuntimeHostTransport {
    var onState: ((RuntimeHostReply) -> Void)?
    var onInterruption: (() -> Void)?
    var requests: [RuntimeHostRequest] = []
    var replies: [Completion] = []
    var disconnections = 0
    func send(_ request: RuntimeHostRequest, completion: @escaping Completion) {
        requests.append(request); replies.append(completion)
    }
    func disconnect() { disconnections += 1 }
    func succeed(_ index: Int, trusted: Bool = true) {
        let request = requests[index]
        replies[index](.success(.init(requestID: request.requestID, permissions: .init(processID: 42, accessibilityTrusted: trusted, checkedAt: Date()), sessionID: request.sessionID, revision: request.revision)))
    }
}

@MainActor
private final class RuntimeTestClock {
    var pending: [(Duration, CheckedContinuation<Void, any Error>)] = []
    func sleep(_ delay: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { pending.append((delay, $0)) }
    }
    func advance() { pending.removeFirst().1.resume() }
    func finish() {
        let old = pending; pending.removeAll()
        for (_, continuation) in old { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class HostFixture {
    let system = HostSystemFixture()
    let transport = HostTransportFixture()
    let clock = RuntimeTestClock()
    var windowRequests: [WindowAgentRequest] = []
    var windowReplies: [WindowAgentXPCClient.Completion] = []
    var windowDisconnects = 0
    var mouseRequests: [MouseAgentRequest] = []
    lazy var window = WindowRuntimeClient(sender: { [unowned self] request, reply in
        self.windowRequests.append(request); self.windowReplies.append(reply)
    }, disconnect: { [unowned self] in self.windowDisconnects += 1 })
    lazy var mouse = MouseRuntimeClient(sender: { [unowned self] request, reply in
        self.mouseRequests.append(request); reply(.failure(.connectionFailed("unused")))
    }, disconnect: {})
    lazy var host = RuntimeHostCoordinator(window: window, mouse: mouse, system: system, transport: transport,
                                          sleep: { [clock] in try await clock.sleep($0) })
    var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.windowManagement.isEnabled = true
        settings.mouseEnhancement.isEnabled = false
        return settings
    }
    func finish() { host.suspend(); clock.finish() }
}

@Suite("后台生命周期", .serialized)
@MainActor
struct RuntimeHostTests {
    @Test("面板等待目标捕获回执，断线和会话切换也必须结束等待")
    func windowTargetCaptureCompletion() throws {
        let fixture = HostFixture()
        defer { fixture.finish() }
        var completions = 0
        fixture.window.captureWindowTarget { id in completions += 1; #expect(id.targetID == nil && id.failureMessage != nil) }
        #expect(completions == 1 && fixture.windowRequests.isEmpty)

        fixture.host.apply(fixture.settings, revision: 1)
        let targetID = UUID()
        let application = AppConfigurationCandidate(displayName: "Editor", bundleIdentifier: "test.editor", processIdentifier: 100)
        fixture.window.captureWindowTarget(application: application) { id in completions += 1; #expect(id == .ready(targetID)) }
        #expect(completions == 1)
        #expect(fixture.windowRequests[0].operation == .captureTarget)
        #expect(fixture.windowRequests[0].captureApplication == application)
        let captureData = try JSONEncoder().encode(fixture.windowRequests[0])
        let decoded = try JSONDecoder().decode(WindowAgentRequest.self, from: captureData)
        try decoded.validate()
        #expect(decoded.captureApplication == application)
        #expect(throws: RuntimeAgentIPCError.self) {
            try WindowAgentRequest(operation: .fetchState, captureApplication: application).validate()
        }
        let state = WindowAgentRuntimeSnapshot(lifecycle: .running, processID: 42, launchID: UUID(),
            accessibilityTrusted: true, accessibilityOperational: true)
        fixture.windowReplies[0](.success(.init(requestID: fixture.windowRequests[0].requestID, state: state, targetCapture: .ready(targetID))))
        #expect(completions == 2 && fixture.window.lastResponseAt != nil)

        fixture.window.perform(.leftHalf, targetID: targetID)
        #expect(fixture.windowRequests.last?.targetID == targetID)
        let actionRequest = fixture.windowRequests[1]
        let data = try JSONEncoder().encode(actionRequest)
        #expect(try JSONDecoder().decode(WindowAgentRequest.self, from: data).targetID == targetID)
        #expect(throws: RuntimeAgentIPCError.self) {
            try WindowAgentReply(requestID: UUID(), state: state).validate(operation: .captureTarget)
        }
        fixture.windowReplies[1](.success(.init(requestID: actionRequest.requestID, state: state, result: .init(succeeded: true))))

        fixture.window.captureWindowTarget { id in completions += 1; #expect(id.targetID == nil && id.failureMessage != nil) }
        fixture.windowReplies[2](.failure(.connectionFailed("test")))
        #expect(completions == 3 && fixture.window.lastResponseAt == nil)

        fixture.window.captureWindowTarget { id in completions += 1; #expect(id.targetID == nil && id.failureMessage != nil) }
        fixture.host.suspend()
        fixture.windowReplies[3](.success(.init(requestID: fixture.windowRequests[3].requestID, state: state, targetCapture: .ready(targetID))))
        #expect(completions == 4)
        #expect(fixture.window.snapshot.lifecycle == .stopped && fixture.window.lastResponseAt == nil)

        fixture.host.apply(fixture.settings, revision: 1)
        let rejection = WindowTargetCaptureResult.unavailable("当前没有普通窗口，请先点选要调整的窗口")
        fixture.window.captureWindowTarget { result in
            completions += 1
            #expect(result == rejection && result.targetID == nil)
        }
        let reply = WindowAgentReply(requestID: fixture.windowRequests.last!.requestID, state: state, targetCapture: rejection)
        let roundTrip = try JSONDecoder().decode(WindowAgentReply.self, from: JSONEncoder().encode(reply))
        try roundTrip.validate(operation: .captureTarget)
        fixture.windowReplies.last!(.success(roundTrip))
        #expect(completions == 5)
        #expect(fixture.window.snapshot.lifecycle == .running && fixture.window.lastResponseAt != nil)

        let service = WindowManagementService(bridge: fixture.window)
        let healthy = fixture.window.snapshot
        let requests = fixture.windowRequests.count
        var feedback: [String] = []
        service.userFeedbackHandler = { feedback.append($0) }
        service.perform(.fill, target: rejection)
        service.reportFailure("没有可添加的外部 App")
        #expect(feedback.count == 2)
        #expect(fixture.windowRequests.count == requests && fixture.window.snapshot == healthy)
    }

    @Test("运行实例隔离，暂停取消命令且旧回包不能复活")
    func runtimeInstanceOwnership() {
        let first = HostFixture(), second = HostFixture()
        defer { first.finish(); second.finish() }
        first.host.apply(first.settings, revision: 1); second.host.apply(second.settings, revision: 1)
        first.window.refresh(); second.window.refresh()
        #expect(first.windowRequests.count == 1 && second.windowRequests.count == 1)
        #expect(first.windowRequests[0].sessionID != second.windowRequests[0].sessionID)
        first.host.suspend()
        first.host.retryConnection()
        first.window.refresh(); second.window.refresh()
        #expect(first.windowRequests.count == 1 && second.windowRequests.count == 2)
        first.transport.succeed(0)
        first.windowReplies[0](.success(.init(requestID: first.windowRequests[0].requestID,
            state: .init(lifecycle: .running, processID: 42, launchID: UUID(), accessibilityTrusted: true, accessibilityOperational: true))))
        #expect(!first.host.hasConnectedRuntime)
        #expect(first.window.snapshot.lifecycle == .stopped)
        #expect(first.windowDisconnects >= 2)
    }

    @Test("反复刷新健康会话不清空状态、不重连、不改写会话")
    func healthyRuntimeRefreshIsNonDisruptive() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.transport.succeed(0)
        fixture.window.receive(.init(lifecycle: .running, processID: 42, launchID: UUID(),
            accessibilityTrusted: true, accessibilityOperational: true))
        let disconnections = fixture.windowDisconnects
        let hostDisconnections = fixture.transport.disconnections
        for _ in 0..<10 {
            fixture.host.retryConnection()
            fixture.host.refreshState()
            fixture.host.refreshState() // 合并尚未完成的同一次刷新。
            fixture.transport.succeed(fixture.transport.requests.count - 1)
            #expect(fixture.window.snapshot.lifecycle == .running)
            #expect(fixture.window.snapshot.accessibilityOperational)
        }
        #expect(fixture.windowRequests.isEmpty)
        #expect(fixture.transport.requests.dropFirst().allSatisfy { $0.operation == .refresh })
        #expect(fixture.windowDisconnects == disconnections)
        #expect(fixture.transport.disconnections == hostDisconnections)
        #expect(fixture.transport.requests.count == 11)
        #expect(fixture.system.saved.count == 1 && fixture.system.registrations == 1)
        fixture.host.suspend()
        fixture.host.refreshState()
        #expect(fixture.windowRequests.isEmpty && fixture.transport.requests.count == 11)
    }

    @Test("手动检查等待对应回执；合并请求、超时、暂停与旧回包都有明确终态")
    func explicitStateCheckCompletion() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.transport.succeed(0)
        let disconnections = fixture.transport.disconnections
        var successes = 0
        var failures: [String] = []
        let completion: RuntimeHostCoordinator.StateCheckCompletion = { result in
            switch result {
            case .success: successes += 1
            case let .failure(error): failures.append(error.localizedDescription)
            }
        }
        fixture.host.refreshState()
        fixture.host.checkState(completion: completion)
        fixture.host.checkState(completion: completion)
        #expect(fixture.transport.requests.count == 2 && successes == 0 && failures.isEmpty)
        let request = fixture.transport.requests[1]
        fixture.transport.onState?(.init(permissions: .init(processID: 42, accessibilityTrusted: true, checkedAt: Date()),
                                        sessionID: request.sessionID, revision: request.revision))
        #expect(successes == 0) // 广播不代表当前检查完成。
        fixture.transport.succeed(1)
        #expect(successes == 2 && failures.isEmpty)
        #expect(fixture.transport.disconnections == disconnections && fixture.system.saved.count == 1)

        fixture.host.checkState(completion: completion)
        fixture.transport.replies[2](.failure(.connectionFailed("请求超时")))
        #expect(failures.count == 1 && failures[0].contains("请求超时"))
        fixture.transport.succeed(2)
        #expect(successes == 2 && failures.count == 1)

        fixture.host.checkState(completion: completion)
        #expect(fixture.transport.requests.count == 4 && fixture.transport.requests[3].operation == .refresh)
        fixture.host.suspend()
        fixture.transport.succeed(3)
        #expect(successes == 2 && failures.count == 2)
        fixture.host.checkState(completion: completion)
        #expect(failures.count == 3 && fixture.transport.requests.count == 4)
    }

    @Test("全关检查不唤醒后台，Finder 按需检查等待回包，注册失败直接返回原因")
    func explicitStateCheckActivationBoundary() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        var settings = fixture.settings
        settings.windowManagement.isEnabled = false
        settings.finder.menuConfiguration.isEnabled = false
        fixture.host.apply(settings, revision: 1)
        var successes = 0
        fixture.host.checkState { result in
            if case .success = result { successes += 1 }
            else { Issue.record("全关无需连接后台") }
        }
        #expect(successes == 1 && fixture.transport.requests.isEmpty)
        settings.finder.menuConfiguration.isEnabled = true
        fixture.host.apply(settings, revision: 2)
        #expect(fixture.transport.requests.isEmpty)
        fixture.host.checkState { result in
            if case .success = result { successes += 1 }
            else { Issue.record("有效回包应完成检查") }
        }
        #expect(successes == 1 && fixture.transport.requests.count == 1)
        #expect(fixture.transport.requests[0].operation == .refresh)
        fixture.transport.succeed(0)
        #expect(successes == 2)

        let failed = HostFixture()
        defer { failed.finish() }
        failed.system.failSave = true
        failed.host.apply(failed.settings, revision: 1)
        var failure: String?
        failed.host.checkState { result in
            if case let .failure(error) = result { failure = error.localizedDescription }
        }
        #expect(failure != nil && failed.transport.requests.isEmpty)
    }

    @Test("切换语言后控制、窗口和鼠标请求使用数据库已提交的后台代次")
    func runtimeLanguageRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        defer { try? repository.database.close() }
        let fixture = HostFixture()
        defer { fixture.finish() }
        var settings = fixture.settings
        settings.mouseEnhancement.isEnabled = true
        let initial = try repository.save(settings)
        fixture.host.apply(initial.settings, revision: initial.revision.runtime)
        fixture.transport.succeed(0)
        let sessionID = try #require(fixture.system.saved.last).id

        // 用真实持久化计算代次，避免测试手填版本掩盖语言与连接层判断不一致。
        for language in [ArcKitLanguage.english, .simplifiedChinese, .system] {
            settings.language = language
            let committed = try repository.save(settings)
            fixture.host.apply(committed.settings, revision: committed.revision.runtime)
            let request = try #require(fixture.transport.requests.last)
            #expect(request.revision == committed.revision.runtime)
            #expect(request.sessionID == sessionID)
            #expect(fixture.system.saved.last?.revision == committed.revision.runtime)
            fixture.window.captureWindowTarget { _ in }
            fixture.mouse.refresh()
            #expect(fixture.windowRequests.last?.revision == committed.revision.runtime)
            #expect(fixture.mouseRequests.last?.revision == committed.revision.runtime)
            fixture.transport.succeed(fixture.transport.requests.count - 1)
            #expect(fixture.host.hasConnectedRuntime)
        }
        let count = fixture.transport.requests.count
        settings.showDockIcon.toggle()
        settings.mouseEnhancement.appProfiles[0].note = "仅修改说明"
        let uiOnly = try repository.save(settings)
        fixture.host.apply(uiOnly.settings, revision: uiOnly.revision.runtime)
        #expect(fixture.transport.requests.count == count)
        #expect(fixture.system.unregistrations == 0)
    }

    @Test("Finder 按需注册，界面设置不推进后台代次，全关不唤醒")
    func runtimeConfigurationBoundary() throws {
        let fixture = HostFixture()
        defer { fixture.finish() }
        var settings = fixture.settings
        settings.windowManagement.isEnabled = false
        settings.finder.menuConfiguration.isEnabled = true
        fixture.host.apply(settings, revision: 1)
        #expect(fixture.system.registrations == 1)
        #expect(fixture.transport.requests.isEmpty)
        let original = try #require(fixture.system.saved.last)
        settings.showDockIcon.toggle()
        fixture.host.apply(settings, revision: 1)
        #expect(fixture.system.saved.last == original)
        #expect(fixture.system.registrations == 1)
        settings.mouseEnhancement.isEnabled = true
        fixture.host.apply(settings, revision: 2)
        let requests = fixture.transport.requests.count
        let disconnections = fixture.transport.disconnections
        let saves = fixture.system.saved.count
        for note in ["远程滚动保持原样", ""] {
            settings.mouseEnhancement.appProfiles[0].note = note
            fixture.host.apply(settings, revision: 2)
            #expect(fixture.transport.requests.count == requests)
            #expect(fixture.transport.disconnections == disconnections)
            #expect(fixture.system.saved.count == saves)
        }
        settings.mouseEnhancement.appProfiles[0].behavior = .custom
        fixture.host.apply(settings, revision: 3)
        #expect(fixture.transport.requests.count == requests + 1)
        #expect(fixture.system.saved.count == saves + 1)
        settings.mouseEnhancement.isEnabled = false
        settings.finder.menuConfiguration.isEnabled = false
        fixture.host.apply(settings, revision: 4)
        #expect(fixture.system.unregistrations == 1 && fixture.system.removals == 1)
        #expect(fixture.transport.requests.count == requests + 1)
    }

    @Test("连续失败只重连三次，暂停使排队重试失效，显式刷新可恢复")
    func boundedRuntimeRecovery() async throws {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        for index in 0..<3 {
            fixture.transport.replies[index](.failure(.connectionFailed("test")))
            try await waitForRuntimeState { !fixture.clock.pending.isEmpty }
            #expect(fixture.clock.pending[0].0 == .seconds(index + 1))
            fixture.clock.advance()
            try await waitForRuntimeState { fixture.transport.requests.count == index + 2 }
        }
        fixture.transport.replies[3](.failure(.connectionFailed("test")))
        #expect(fixture.transport.requests.count == 4)
        #expect(fixture.clock.pending.isEmpty)
        for _ in 0..<10 { fixture.host.refreshState() }
        #expect(fixture.transport.requests.count == 4 && fixture.windowRequests.isEmpty)
        fixture.host.retryConnection()
        #expect(fixture.transport.requests.count == 5)
        fixture.transport.replies[4](.failure(.connectionFailed("test")))
        try await waitForRuntimeState { !fixture.clock.pending.isEmpty }
        fixture.host.suspend()
        fixture.clock.advance()
        await Task.yield()
        #expect(fixture.transport.requests.count == 5)
        #expect(!fixture.host.hasConnectedRuntime)
    }

    @Test("会话写入失败不开放业务命令，显式刷新在写入成功后恢复")
    func failedSessionDoesNotActivateClients() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.system.failSave = true
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.window.refresh()
        #expect(fixture.windowRequests.isEmpty && fixture.transport.requests.isEmpty)
        fixture.system.failSave = false
        fixture.host.retryConnection()
        fixture.window.refresh()
        #expect(fixture.windowRequests.count == 1 && fixture.transport.requests.count == 1)
    }

    @Test("退出和卸载都要求停止证据，卸载准备失败恢复注册")
    func runtimeRemovalEvidence() async throws {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.system.stopped = false
        do {
            try await fixture.host.unregisterForQuit()
            Issue.record("查询未确认停止时不能报告退出成功")
        } catch {}
        fixture.host.apply(fixture.settings, revision: 1)
        do {
            _ = try await fixture.host.unregisterForUninstall()
            Issue.record("后台仍存在时不能开始删除应用")
        } catch {}
        #expect(fixture.system.restorations == 1)
        #expect(fixture.system.mainAppRemovals == 0)
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.system.stopped = true
        try await fixture.host.unregisterForQuit()
        #expect(!fixture.host.hasConnectedRuntime)
    }
}

extension RuntimeHostTests {
    @Test("运行会话绑定进程启动时间并限制文件大小")
    func sessionIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.json")
        let session = try RuntimeHostSession(windowEnabled: true, mouseEnabled: false, finderEnabled: true)
        try session.save(to: url)
        #expect(try RuntimeHostSession.load(from: url).id == session.id)
        #expect(try RuntimeHostSession.load(from: url).isOwnerAlive)
        #expect(try !RuntimeHostSession.load(from: url).hasEnabledFeatures)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["revision"] == nil && object["windowEnabled"] == nil)
        object["startedSeconds"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: (any Error).self) { try RuntimeHostSession.load(from: url) }
        try Data(repeating: 0, count: 8193).write(to: url)
        #expect(throws: (any Error).self) { try RuntimeHostSession.load(from: url) }
    }

    @Test("查询失败不能当作注销完成")
    func strictJobRemovalEvidence() {
        let label = ArcKitConstants.runtimeHostLaunchAgentIdentifier
        #expect(RuntimeHostLaunchJobProbe.confirmsJobRemoval(.completed(status: 113, output: "Could not find service \"\(label)\" in domain for user gui: 501"), label: label))
        #expect(!RuntimeHostLaunchJobProbe.confirmsJobRemoval(.timedOut, label: label))
        #expect(!RuntimeHostLaunchJobProbe.confirmsJobRemoval(.completed(status: 1, output: "Operation not permitted"), label: label))
    }
}

@MainActor
private func waitForRuntimeState(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(predicate(), "后台状态未在期限内更新")
}


extension RuntimeHostTests {
    @Test("断线立即撤销健康证据，未授权只由有效回包确认")
    func permissionEvidenceFollowsConnection() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        var state = WindowAgentRuntimeSnapshot(lifecycle: .waitingForAccessibility, processID: 101,
            launchID: UUID(), accessibilityTrusted: false, accessibilityOperational: false)
        fixture.window.receive(state)
        var report = FeatureHealthAssessment.window(settings: fixture.settings.windowManagement,
            snapshot: fixture.window.snapshot, receivedAt: fixture.window.lastResponseAt)
        #expect(report.permission == .denied && report.action == .accessibility)
        state.lifecycle = .running
        state.accessibilityTrusted = true
        state.accessibilityOperational = true
        state.hotKeyRegisteredCount = fixture.settings.windowManagement.bindings.filter(\.isEnabled).count
        state.dragSnapState = .running
        fixture.window.receive(state)
        report = FeatureHealthAssessment.window(settings: fixture.settings.windowManagement,
            snapshot: fixture.window.snapshot, receivedAt: fixture.window.lastResponseAt)
        #expect(report.state == .ready)
        var changed = fixture.settings
        changed.windowManagement.dragSnapEnabled.toggle()
        fixture.host.apply(changed, revision: 2)
        #expect(fixture.window.lastResponseAt == nil)
        #expect(FeatureHealthAssessment.window(settings: changed.windowManagement,
            snapshot: fixture.window.snapshot, receivedAt: fixture.window.lastResponseAt).permission == .unknown)
        fixture.window.receive(state)
        fixture.transport.onInterruption?()
        report = FeatureHealthAssessment.window(settings: fixture.settings.windowManagement,
            snapshot: fixture.window.snapshot, receivedAt: fixture.window.lastResponseAt)
        #expect(fixture.window.lastResponseAt == nil)
        #expect(report.permission == .unknown && report.action == .refresh)
        #expect(report.state == .blocked)
    }

    @Test("陈旧回包、旧配置回包和 Debug 不能伪装已授权或已生效")
    func healthEvidenceBoundaries() {
        var settings = MouseEnhancementSettings.defaults
        settings.isEnabled = true
        let now = Date()
        let state = MouseAgentRuntimeSnapshot(lifecycle: .running, processID: 101, launchID: UUID(), accessibilityTrusted: true)
        let stale = FeatureHealthAssessment.mouse(settings: settings, snapshot: state, receivedAt: now.addingTimeInterval(-31), now: now)
        #expect(stale.permission == .unknown && stale.state == .unknown)
        let preview = FeatureHealthAssessment.mouse(settings: settings, snapshot: state, receivedAt: now, preview: true, now: now)
        #expect(preview.state == .preview && preview.permission == .unknown)
        let client = MouseRuntimeClient(sender: { _, _ in }, disconnect: {})
        let sessionID = UUID()
        client.configure(context: .init(sessionID: sessionID, revision: 1))
        client.receive(state)
        #expect(client.lastResponseAt != nil)
        client.configure(context: .init(sessionID: sessionID, revision: 2))
        #expect(client.lastResponseAt == nil)
        let health = AppRuntimeHealthModel(isPreview: true, finderHealthProvider: { fatalError("Debug 不允许探测安装版") })
        health.refresh(force: true)
        #expect(!health.isRefreshing && health.finderHealth == nil)
    }

    @Test("Finder 检测回执按 UUID 关联，经过 IPC 和文件后保留精度与菜单覆盖前的回应")
    func finderResponseCorrelation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000.875)
        let path = ArcKitConstants.installedAppPath + "/Contents/PlugIns/ArcKitFinderExtension.appex"
        var state = FinderExtensionRuntimeState(
            generatedAt: now, processID: 42, bundleIdentifier: ArcKitConstants.finderExtensionBundleIdentifier,
            bundlePath: path, executablePath: path + "/Contents/MacOS/ArcKitFinderExtension",
            event: .menuBuilt, recentStateResponses: [.init(requestID: requestID, respondedAt: now.addingTimeInterval(-0.125))],
            snapshotVersion: FinderExtensionSnapshot.currentSchemaVersion, isMenuCachePrepared: true,
            observedDirectoryPaths: [])
        let store = FinderExtensionRuntimeStateStore(stateURL: root.appendingPathComponent("state.json"), processIsRunning: { _ in true })
        let wire = try FinderAgentSecureIPCCodec.encode(state)
        try store.record(FinderAgentSecureIPCCodec.decode(FinderExtensionRuntimeState.self, from: wire))
        let restored = try store.loadAll()
        #expect(restored == [state])
        func accepts(_ states: [FinderExtensionRuntimeState], id: UUID = requestID, at: Date = now) -> Bool {
            FinderExtensionStatusService.extensionHasResponse(states, requestID: id, now: at, isRunning: { $0 == 42 })
        }
        #expect(accepts(restored), "同秒回应有效，后续 menuBuilt 不抹掉回执")
        #expect(!accepts(restored, id: UUID()))
        #expect(!accepts(restored, at: now.addingTimeInterval(31)))
        #expect(!FinderExtensionStatusService.extensionHasResponse(restored, requestID: requestID, now: now, isRunning: { _ in false }))
        state.bundlePath = "/tmp/ArcKitFinderExtension.appex"
        #expect(!accepts([state]))
    }

    @Test("Finder 按需休眠不是故障，未回应不是未授权")
    func finderEvidenceBoundaries() {
        let now = Date()
        var facts = FinderExtensionStatusService.HealthStatus(
            checkedAt: now, snapshotExists: true, snapshotAgeDescription: "", extensionFileExists: true,
            expectedExtensionPath: "", extensionEnabledByUser: true, extensionRuntimeResponded: true,
            extensionRuntimeAgeDescription: "", plugInKitRegistered: true, plugInKitPathVerified: true,
            plugInKitOnlyCurrentPath: true, plugInKitSummary: "", agentFileExists: true, agentRunning: false,
            agentProcessPathVerified: false, agentOnlyCurrentProcess: false, agentProcessSummary: "",
            launchAgentPlistExists: true, launchAgentSecureServiceConfigured: true, launchAgentLoaded: true,
            launchAgentDescription: "", commandChannelDescription: "")
        #expect(FeatureHealthAssessment.finder(enabled: true, health: facts, now: now).state == .ready)
        facts.launchAgentLoaded = false
        #expect(FeatureHealthAssessment.finder(enabled: true, health: facts, now: now).action == .refresh)
        facts.launchAgentRequiresApproval = true
        #expect(FeatureHealthAssessment.finder(enabled: true, health: facts, now: now).action == .loginItems)
        facts.launchAgentLoaded = true
        facts.launchAgentRequiresApproval = false
        facts.extensionRuntimeResponded = false
        let waiting = FeatureHealthAssessment.finder(enabled: true, health: facts, now: now)
        #expect(waiting.state == .unknown && waiting.permission == .granted)
        #expect(waiting.action == .refresh)
        facts.extensionEnabledByUser = false
        #expect(FeatureHealthAssessment.finder(enabled: true, health: facts, now: now).action == .extensionSettings)
        facts.checkedAt = now.addingTimeInterval(-31)
        #expect(FeatureHealthAssessment.finder(enabled: true, health: facts, now: now).permission == .unknown)
        #expect(FeatureHealthAssessment.finder(enabled: false, health: facts, now: now).state == .disabled)
    }
}


extension RuntimeHostTests {
    @Test("授权只由显式请求触发，重复点击合并，断线和旧回包不恢复授权证据")
    func explicitPermissionRequest() {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.transport.succeed(0)
        fixture.host.refreshState()
        fixture.transport.succeed(1)
        #expect(!fixture.transport.requests.contains { $0.operation == .requestAccessibility })
        var completions = 0
        fixture.host.requestAccessibilityPermission { _ in completions += 1 }
        fixture.host.requestAccessibilityPermission { _ in completions += 1 }
        #expect(fixture.transport.requests.count == 3)
        #expect(fixture.transport.requests[2].operation == .requestAccessibility)
        #expect(fixture.host.permissions.isRequesting)
        fixture.transport.replies[2](.failure(.connectionFailed("test disconnected")))
        #expect(completions == 1 && !fixture.host.permissions.isRequesting)
        #expect(fixture.host.permissions.accessibilityEvidence() == .unknown)
        fixture.transport.succeed(2)
        #expect(fixture.host.permissions.accessibilityEvidence() == .unknown && completions == 1)
        #expect(fixture.host.permissions.requestFailure != nil)
        fixture.host.suspend()
        fixture.host.requestAccessibilityPermission { _ in completions += 1 }
        #expect(fixture.transport.requests.count == 3)

        let pending = HostFixture()
        defer { pending.finish() }
        pending.host.apply(pending.settings, revision: 1)
        pending.transport.succeed(0, trusted: false)
        pending.host.requestAccessibilityPermission { _ in }
        pending.transport.succeed(1, trusted: false)
        #expect(pending.host.permissions.isAwaitingApproval && !pending.host.permissions.isRequesting)
        pending.host.requestAccessibilityPermission { _ in Issue.record("等待系统授权时不能重复投递") }
        #expect(pending.transport.requests.count == 2)
        pending.host.permissions.finishApprovalWait()
        pending.host.requestAccessibilityPermission { _ in }
        #expect(pending.transport.requests.count == 3)
    }

    @Test("授权面板区分两个进程、后台许可、过期证据与实际窗口可用性")
    func permissionOwnersAndFreshness() {
        let now = Date()
        let permissions = ApplicationPermissions(isPreview: false)
        #expect(permissions.accessibilityHealth(required: true, now: now).permission == .unknown)
        permissions.receive(.init(processID: 42, accessibilityTrusted: false, checkedAt: now))
        #expect(permissions.accessibilityHealth(required: true, now: now).action == .accessibility)
        #expect(permissions.accessibilityHealth(required: true, now: now.addingTimeInterval(31)).permission == .unknown)
        permissions.receive(.init(processID: 42, accessibilityTrusted: true, checkedAt: now))
        permissions.receiveSystem(.init(checkedAt: now, background: .requiresApproval, finderEnabled: true, menuInputAllowed: false))
        #expect(permissions.accessibilityHealth(required: true, now: now).action == .loginItems)
        #expect(permissions.backgroundHealth(required: true, now: now).state == .blocked)
        #expect(permissions.menuInputHealth(required: true, now: now).action == .inputMonitoring)
        #expect(permissions.finderHealth(required: true, now: now).permission == .granted)
        permissions.receiveSystem(.init(checkedAt: now, background: .enabled, finderEnabled: false, menuInputAllowed: true))
        #expect(permissions.accessibilityHealth(required: true, now: now).permission == .granted)
        #expect(permissions.backgroundHealth(required: true, now: now).permission == .granted)
        #expect(permissions.finderHealth(required: true, now: now).permission == .denied)
        #expect(permissions.menuInputHealth(required: false, now: now).permission == .notRequired)
        permissions.receiveSystem(.init(checkedAt: now, background: .enabled, finderEnabled: false, menuInputAllowed: false))
        let windowReady = FeatureHealth(state: .ready, title: "Ready", detail: "", permission: .granted)
        #expect(permissions.windowHealth(windowReady, required: true, menuBarVisible: false, now: now).state == .ready)
        #expect(permissions.windowHealth(windowReady, required: true, menuBarVisible: true, now: now).state == .partial)
        #expect(permissions.backgroundHealth(required: true, now: now.addingTimeInterval(31)).permission == .unknown)
        permissions.invalidateRuntime()
        #expect(permissions.accessibilityHealth(required: true, now: now).permission == .unknown)
        let preview = ApplicationPermissions()
        preview.refreshSystem()
        #expect(preview.system == nil && preview.accessibilityHealth(required: true).state == .preview)
    }
}


@MainActor
private final class LoginPermissionFixture: LaunchAtLoginManaging {
    var status: LaunchAtLoginRegistrationStatus = .requiresApproval
    var registrations = 0
    var unregistrations = 0
    func register() throws { registrations += 1 }
    func unregister() throws { unregistrations += 1; status = .notRegistered }
    func openSystemSettings() { Issue.record("只读验证不能打开系统设置") }
}

extension RuntimeHostTests {
    @Test("登录启动等待许可不重复注册、不误报成功，关闭必须确认注销")
    func loginApprovalIsNotRegistrationFailure() {
        let manager = LoginPermissionFixture()
        let service = LaunchAtLoginService(manager: manager)
        #expect(service.applyLaunchAtLogin(enabled: true) == .requiresApproval)
        #expect(service.applyLaunchAtLogin(enabled: true) == .requiresApproval)
        #expect(manager.registrations == 0 && service.launchAtLoginState == .requiresApproval)
        #expect(service.lastLaunchAtLoginError == nil && service.failedLaunchAtLoginDesiredState == nil)
        manager.status = .enabled
        service.refreshLaunchAtLoginStatus()
        #expect(service.launchAtLoginState == .enabled)
        #expect(service.applyLaunchAtLogin(enabled: false) == .effective)
        #expect(manager.unregistrations == 1 && service.launchAtLoginState == .disabled)
    }
}


extension RuntimeHostTests {
    @Test("重复中断取消旧代次的排队重连，旧任务结束不能阻塞新重连")
    func repeatedInterruptionDoesNotStrandReconnect() async throws {
        let fixture = HostFixture()
        defer { fixture.finish() }
        fixture.host.apply(fixture.settings, revision: 1)
        fixture.transport.onInterruption?()
        try await waitForRuntimeState { fixture.clock.pending.count == 1 }
        fixture.transport.onInterruption?()
        try await waitForRuntimeState { fixture.clock.pending.count == 2 }
        fixture.clock.advance()
        fixture.clock.advance()
        try await waitForRuntimeState { fixture.transport.requests.count == 2 }
        fixture.transport.succeed(0)
        #expect(!fixture.host.hasConnectedRuntime)
        fixture.transport.succeed(1)
        #expect(fixture.host.hasConnectedRuntime)
    }
}
