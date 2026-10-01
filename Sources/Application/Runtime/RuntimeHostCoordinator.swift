import ArcKitPlatform
import ArcKitWindow
import ArcKitMouse
import Foundation

/// 应用实例拥有的唯一 Host 协调器。系统注册、XPC 传输和业务状态分别注入，禁止全局可变状态。
@MainActor
final class RuntimeHostCoordinator {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias StateCheckCompletion = (Result<Void, RuntimeHostRegistrationError>) -> Void

    let permissions: ApplicationPermissions
    private var refreshing = false
    private var refreshCompletions: [StateCheckCompletion] = []
    private let window: WindowRuntimeClient
    private let mouse: MouseRuntimeClient
    private let system: any RuntimeHostSystem
    private let transport: any RuntimeHostTransport
    private let sleep: Sleeper
    private var session: RuntimeHostSession?
    private var acceptsConnections = false
    private var allowsConnectionRetry = false
    private var isTerminating = false
    private(set) var hasConnectedRuntime = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(window: WindowRuntimeClient, mouse: MouseRuntimeClient,
         system: any RuntimeHostSystem = InstalledRuntimeHostSystem(),
         permissions: ApplicationPermissions = ApplicationPermissions(),
         transport: any RuntimeHostTransport = RuntimeHostXPCTransport(),
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.permissions = permissions
        self.window = window; self.mouse = mouse
        self.system = system; self.transport = transport; self.sleep = sleep
        transport.onState = { [weak self] in _ = self?.consume($0) }
        transport.onInterruption = { [weak self] in self?.interrupted() }
    }

    func apply(_ settings: AppSettings, revision: UInt64) {
        guard !isTerminating else { return }
        // 数据库的已提交代次是唯一失效依据，不能另列字段而遗漏语言等后台依赖。
        // 登录项、外观和规则说明不推进此代次，因此不会重连或刷新恢复预算。
        guard !acceptsConnections || session?.revision != revision else { return }
        let previouslyContinuous = session?.needsContinuousRuntime == true
        suspend()
        allowsConnectionRetry = true
        do {
            var current = try session ?? RuntimeHostSession(windowEnabled: false, mouseEnabled: false, finderEnabled: false)
            current.revision = revision
            current.windowEnabled = settings.windowManagement.isEnabled
            current.mouseEnabled = settings.mouseEnhancement.isEnabled
            current.finderEnabled = settings.finder.menuConfiguration.isEnabled
            session = current
            guard system.isInstalled else { return }
            try system.save(current)
            if !current.hasEnabledFeatures {
                // 同一 MainActor 转内注销，不能用迟到的 stop 终止下一次启用。
                try system.unregisterHost()
                try system.removeSession()
                system.invalidateFinderSnapshot()
                return
            }
            try system.ensureRegistered()
            activate(current)
            ArcKitLog.append("runtime session applied revision=\(current.revision)")
            reconnectAttempts = 0
            // Finder-only 冷启动仅注册；PID 缺失不等于失效，也不需要唤醒。
            if current.needsContinuousRuntime || previouslyContinuous || system.isRunning { connect(.reload) }
        } catch { recordFailure(error.localizedDescription) }
    }

    private func activate(_ session: RuntimeHostSession) {
        acceptsConnections = true
        let context = RuntimeRequestContext(sessionID: session.id, revision: session.revision)
        window.configure(context: session.windowEnabled ? context : nil)
        mouse.configure(context: session.mouseEnabled ? context : nil)
    }

    func suspend() {
        generation &+= 1
        acceptsConnections = false
        allowsConnectionRetry = false
        hasConnectedRuntime = false
        refreshing = false
        permissions.invalidateRuntime()
        reconnectTask?.cancel(); reconnectTask = nil
        stableTask?.cancel(); stableTask = nil
        window.configure(context: nil)
        mouse.configure(context: nil)
        transport.disconnect()
        finishRefresh(.failure(.failure(L10n.string(.Runtime.connectionRuntimeSessionChangedStoppedCheck))))
    }

    /// 查询只读取现有会话，权限变化由对应功能按需恢复，不能清空 UI 快照。
    func refreshState() {
        guard !isTerminating, acceptsConnections, hasConnectedRuntime else { return }
        startRefresh()
    }

    /// 用户发起的检查必须有终态；广播和旧快照不能代替本次请求的回执。
    func checkState(completion: @escaping StateCheckCompletion) {
        guard !isTerminating, allowsConnectionRetry, let session else {
            completion(.failure(.failure(L10n.string(.Runtime.connectionBackgroundSessionNotReadyRetryLater))))
            return
        }
        guard session.hasEnabledFeatures else { completion(.success(())); return }
        guard system.isInstalled else {
            completion(.failure(.failure(L10n.string(.Runtime.connectionOpenInstalledArcKitApplications))))
            return
        }
        // 与普通刷新合并，重复点击不会取消前一次检查或重建连接。
        if refreshing { refreshCompletions.append(completion); return }
        do {
            if !hasConnectedRuntime { try prepareConnectionRetry() }
            refreshCompletions.append(completion)
            startRefresh()
        } catch {
            recordFailure(error.localizedDescription)
            completion(.failure(.failure(error.localizedDescription)))
        }
    }

    private func startRefresh() {
        guard !refreshing else { return }
        refreshing = true
        connect(.refresh)
    }

    private func finishRefresh(_ result: Result<Void, RuntimeHostRegistrationError>) {
        refreshing = false
        let completions = refreshCompletions
        refreshCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    /// 授权命令不自动重试。超时、断线和会话变更都结束本次申请，由用户决定再次申请。
    func requestAccessibilityPermission(completion: @escaping (Bool) -> Void) {
        guard !permissions.isRequesting, !permissions.isAwaitingApproval, session?.needsContinuousRuntime == true else { return }
        retryConnection()
        guard acceptsConnections, !isTerminating, let session else {
            permissions.finishRequest(error: L10n.string(.Runtime.connectionDisconnected))
            completion(false)
            return
        }
        permissions.beginRequest()
        let expectedGeneration = generation
        transport.send(RuntimeHostRequest(.requestAccessibility, sessionID: session.id, revision: session.revision)) { [weak self] result in
            guard let self, self.acceptsConnections, self.generation == expectedGeneration else { return }
            switch result {
            case let .success(reply):
                guard self.consume(reply) else {
                    self.permissions.finishRequest(error: reply.errorMessage ?? L10n.string(.Runtime.connectionInvalidPermissionResponse))
                    completion(false)
                    return
                }
                self.permissions.finishRequest()
                completion(true)
            case let .failure(error):
                self.interrupted(reason: error.localizedDescription)
                self.permissions.finishRequest(error: error.localizedDescription)
                completion(false)
            }
        }
    }

    /// 仅显式操作可以重置断线恢复预算；普通激活和权限轮询不能调用此入口。
    func retryConnection() {
        guard !isTerminating, !hasConnectedRuntime, allowsConnectionRetry,
              let session, session.hasEnabledFeatures, system.isInstalled else { return }
        do {
            try prepareConnectionRetry()
            connect(.connect)
        } catch { recordFailure(error.localizedDescription) }
    }

    private func prepareConnectionRetry() throws {
        guard let session else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionBackgroundSessionNotReady)) }
        // 普通暂停后只能由 start/apply 恢复；调用方必须确认允许显式重连。
        suspend()
        allowsConnectionRetry = true
        try system.save(session)
        try system.ensureRegistered()
        activate(session)
        reconnectAttempts = 0
    }

    private func connect(_ operation: RuntimeHostRequest.Operation) {
        guard acceptsConnections, !isTerminating, let session else { return }
        let expectedGeneration = generation
        transport.send(RuntimeHostRequest(operation, sessionID: session.id, revision: session.revision)) { [weak self] result in
            guard let self, self.acceptsConnections, self.generation == expectedGeneration else { return }
            switch result {
            case let .success(reply):
                guard self.consume(reply) else {
                    self.interrupted(reason: reply.errorMessage ?? L10n.string(.Runtime.connectionSessionMismatch))
                    return
                }
                if operation == .refresh { self.finishRefresh(.success(())) }
            case let .failure(error): self.interrupted(reason: error.localizedDescription)
            }
        }
    }

    private func interrupted(reason: String = L10n.string(.Runtime.connectionInterrupted)) {
        defer { finishRefresh(.failure(.failure(reason))) }
        generation &+= 1
        reconnectTask?.cancel(); reconnectTask = nil
        transport.disconnect()
        hasConnectedRuntime = false
        refreshing = false
        permissions.invalidateRuntime()
        // 连接中断立即撤销运行证据，不能在重连期间继续展示旧的“就绪”。
        recordFailure(reason)
        stableTask?.cancel(); stableTask = nil
        guard acceptsConnections, session?.needsContinuousRuntime == true, reconnectTask == nil else { return }
        guard reconnectAttempts < 3 else {
            recordFailure(L10n.string(.Runtime.connectionRetryLimit))
            return
        }
        reconnectAttempts += 1
        let delay = Duration.seconds(reconnectAttempts)
        let expectedGeneration = generation
        let sleep = sleep
        reconnectTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.acceptsConnections else { return }
            self.reconnectTask = nil
            self.connect(.connect)
        }
    }

    @discardableResult
    private func consume(_ reply: RuntimeHostReply) -> Bool {
        guard acceptsConnections, reply.errorMessage == nil,
              reply.sessionID == session?.id, reply.revision == session?.revision,
              let evidence = reply.permissions, evidence.isCurrent() else { return false }
        if let current = permissions.runtime, evidence.checkedAt < current.checkedAt { return true }
        permissions.receive(evidence)
        if !hasConnectedRuntime {
            hasConnectedRuntime = true
            reconnectTask?.cancel(); reconnectTask = nil
            let expectedGeneration = generation
            let sleep = sleep
            stableTask = Task { [weak self] in
                do { try await sleep(.seconds(30)) } catch { return }
                guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.hasConnectedRuntime else { return }
                self.reconnectAttempts = 0
                self.stableTask = nil
            }
        }
        if let data = reply.states["window"], let state = try? RuntimeAgentIPCCodec.decode(WindowAgentRuntimeSnapshot.self, from: data) { window.receive(state) }
        if let data = reply.states["mouse"], let state = try? RuntimeAgentIPCCodec.decode(MouseAgentRuntimeSnapshot.self, from: data) { mouse.receive(state) }
        return true
    }

    private func recordFailure(_ message: String) {
        ArcKitLog.append("runtime host coordinator: \(message)")
        if session?.windowEnabled == true { window.markConnectionUnavailable(message) }
        if session?.mouseEnabled == true { mouse.recordConnectionFailure(message) }
    }

    func unregisterForQuit() async throws {
        guard !isTerminating else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionBackgroundStopping)) }
        isTerminating = true
        suspend()
        defer { isTerminating = false; transport.disconnect() }
        guard system.isInstalled else { return }
        if let session, system.isRunning {
            // 停止回执是尽力而为；是否完成退出以注销和 launchd 的明确证据为准。
            let _: RuntimeHostReply? = try? await withCheckedThrowingContinuation { continuation in
                transport.send(RuntimeHostRequest(.stop, sessionID: session.id, revision: session.revision)) {
                    continuation.resume(with: $0)
                }
            }
        }
        try system.removeSession()
        try system.unregisterHost()
        guard await system.waitUntilStopped() else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionBackgroundJobsRemainShutdownIncomplete)) }
        session = nil
        system.invalidateFinderSnapshot()
    }

    func unregisterForUninstall() async throws -> RuntimeServiceRegistrationSnapshot {
        guard !isTerminating, system.isInstalled else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionUnregisterUnavailable)) }
        isTerminating = true
        suspend()
        defer { isTerminating = false }
        let snapshot = system.registrationSnapshot()
        do {
            try system.removeSession()
            try system.unregisterHost()
            guard await system.waitUntilStopped() else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionStopping)) }
            try system.unregisterMainApp()
            return snapshot
        } catch {
            let failure = error
            do { try restoreAfterFailedUninstall(snapshot) }
            catch { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.connectionUninstallPreparationRecoveryFailed(String(describing: failure.localizedDescription), String(describing: error.localizedDescription)))) }
            throw failure
        }
    }

    func restoreAfterFailedUninstall(_ snapshot: RuntimeServiceRegistrationSnapshot) throws {
        // 卸载预处理已经 suspend；恢复注册后由 ApplicationRuntime.start 重新消费已提交配置。
        if let session { try system.save(session) }
        try system.restoreRegistration(snapshot)
    }
}
