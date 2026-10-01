import AppKit
import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import ArcKitFinderRuntime
import ArcKitWindow
import ArcKitWindowRuntime
import ArcKitMouse
import ArcKitMouseRuntime
import Darwin

/// 唯一后台组合根。业务模块不注册服务、不决定是否重启其他功能。
@MainActor
final class RuntimeHost {
    private var session: RuntimeHostSession
    private let window = WindowRuntimeAgentController()
    private let mouse = MouseRuntimeAgentController()
    private let configuration = HostConfiguration(database: ArcKitDatabase(reading: .current))
    private lazy var finder = FinderAgentController(admissionStore: FinderCommandAdmissionStore(sessionID: session.id), settingsProvider: { [configuration] in configuration.finderSettings() })
    private var appliedRevision: UInt64?
    private var lastWindow: WindowManagementSettings?
    private var lastMouse: MouseEnhancementSettings?
    private var ownerMonitor: DispatchSourceProcess?
    private var idleTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var activities = 0
    private var stopping = false
    private var reloading = false
    private var reloadPending = false
    private var reloadWaiters: [CheckedContinuation<Void, Never>] = []

    private lazy var control = RuntimeAgentXPCServer<RuntimeHostRequest, RuntimeHostReply>(
        serviceName: ArcKitConstants.runtimeHostControlMachServiceName, logLabel: "host",
        handler: { [weak self] request in
            guard let self else { return RuntimeHostReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostBackgroundServiceEnded)) }
            return await self.handle(request)
        }, validateRequest: { try $0.validate() }, validateReply: { _, _ in },
        makeFailureReply: { RuntimeHostReply(requestID: $0, errorMessage: $1) })

    private lazy var windowServer = WindowAgentXPCServer { [weak self] request in
        guard let self, self.beginActivity() else {
            return WindowAgentReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostWindowsOffRuntimeSession))
        }
        defer { self.endActivity() }
        await self.reload()
        guard !self.stopping, self.session.windowEnabled, request.sessionID == self.session.id, request.revision == self.session.revision else { return WindowAgentReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostWindowsOff)) }
        return await self.window.handle(request)
    }
    private lazy var mouseServer = MouseAgentXPCServer { [weak self] request in
        guard let self, self.beginActivity() else {
            return MouseAgentReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostMouseOffRuntimeSession))
        }
        defer { self.endActivity() }
        await self.reload()
        guard !self.stopping, self.session.mouseEnabled, request.sessionID == self.session.id, request.revision == self.session.revision else { return MouseAgentReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostMouseOff)) }
        return self.mouse.handle(request)
    }
    private lazy var finderServer = FinderAgentSecureIPCServer(
        commandHandler: { [weak self] data in
            guard let self, self.beginActivity() else {
                return FinderAgentSecureIPCReply(errorMessage: L10n.string(.HostEntry.hostArcKitStoppedFinderOff))
            }
            defer { self.endActivity() }
            await self.reload()
            guard !self.stopping, self.session.finderEnabled else { return FinderAgentSecureIPCReply(errorMessage: L10n.string(.HostEntry.extensionFinderOff)) }
            return self.finder.acceptSecureCommandData(data)
        }, snapshotProvider: { [weak self] completion in
            guard let self, self.beginActivity() else {
                completion(.failure(.connectionFailed(L10n.string(.HostEntry.hostArcKitStoppedFinderOff)))); return
            }
            Task {
                await self.reload()
                guard !self.stopping, self.session.finderEnabled else {
                    completion(.failure(.connectionFailed(L10n.string(.HostEntry.hostFinderOff)))); self.endActivity(); return
                }
                self.finder.fetchLatestSnapshot { result in completion(result); self.endActivity() }
            }
        }, runtimeStateHandler: { [weak self] state in
            guard let self, self.beginActivity() else { return false }
            defer { self.endActivity() }
            guard self.session.finderEnabled else { return false }
            return self.finder.recordFinderExtensionRuntimeState(state)
        })

    init(session: RuntimeHostSession) { self.session = session }

    func start() {
        ownerMonitor = DispatchSource.makeProcessSource(identifier: session.processID, eventMask: .exit, queue: .main)
        ownerMonitor?.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.shutdown() } }
        ownerMonitor?.resume()
        // 监控建立后再次校验，覆盖 load 到 monitor.resume 之间主应用退出的竞态。
        guard session.isOwnerAlive else { shutdown(); return }
        window.stateDidChange = { [weak self] in self?.schedulePublish() }
        mouse.stateDidChange = { [weak self] in self?.schedulePublish() }
        finder.activityDidChange = { [weak self] in self?.scheduleIdleExit() }
        guard control.start(), windowServer.start(), mouseServer.start(), finderServer.start() else { shutdown(); return }
        Task { await reload() }
    }

    private func beginActivity() -> Bool {
        guard !stopping, let current = try? RuntimeHostSession.load(), current.id == session.id else { return false }
        activities += 1
        idleTask?.cancel(); idleTask = nil
        return true
    }
    private func endActivity() { activities = max(0, activities - 1); scheduleIdleExit() }

    private func handle(_ request: RuntimeHostRequest) async -> RuntimeHostReply {
        guard request.sessionID == session.id, beginActivity() else {
            return RuntimeHostReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostMainAppRuntimeSessionMismatch))
        }
        defer { endActivity() }
        await reload()
        guard !stopping, request.revision == session.revision else {
            ArcKitLog.append("runtime host request rejected operation=\(request.operation.rawValue) requestedRevision=\(request.revision) appliedRevision=\(session.revision) stopping=\(stopping)")
            return RuntimeHostReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostConfigurationUpdatedRetry))
        }
        switch request.operation {
        case .connect, .reload: await reload()
        case .refresh:
            await refreshPermissionsAndServices()
        case .requestAccessibility:
            guard session.needsContinuousRuntime else {
                return RuntimeHostReply(requestID: request.requestID, errorMessage: L10n.string(.HostEntry.hostWindowsMouseOffAccessibility))
            }
            ProcessPermissions.requestAccessibility()
            await refreshPermissionsAndServices()
        case .stop:
            // 先回复，再结束监听；后续请求被 stopping 拒绝。
            stopping = true
            window.stop(); mouse.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.shutdown() }
        }
        return stateReply(requestID: request.requestID)
    }

    private func reload() async {
        reloadPending = true
        guard !stopping else { return }
        if reloading {
            await withCheckedContinuation { reloadWaiters.append($0) }
            return
        }
        reloading = true
        defer {
            reloading = false
            let waiters = reloadWaiters; reloadWaiters.removeAll()
            waiters.forEach { $0.resume() }
            scheduleIdleExit()
            schedulePublish()
        }
        while reloadPending, !stopping {
            reloadPending = false
            guard let current = try? RuntimeHostSession.load(), current.id == session.id else { shutdown(); return }
            do {
                let configuration = configuration
                let snapshot = try await Task.detached { try configuration.read() }.value
                guard current.isOwnerAlive, (try? RuntimeHostSession.load().id) == current.id else { shutdown(); return }
                session = current
                session.revision = snapshot.revision
                session.windowEnabled = snapshot.window.isEnabled
                session.mouseEnabled = snapshot.mouse.isEnabled
                session.finderEnabled = snapshot.finder.menuConfiguration.isEnabled
                L10n.configure(snapshot.language)
                configuration.publish(snapshot.finder)
                if lastMouse?.hasSameRuntimeConfiguration(as: snapshot.mouse) != true {
                    lastMouse = snapshot.mouse
                    mouse.start(settings: snapshot.mouse)
                }
                if lastWindow != snapshot.window { lastWindow = snapshot.window; await window.start(settings: snapshot.window) }
                guard current.isOwnerAlive, !stopping else { shutdown(); return }
                appliedRevision = snapshot.revision
                finder.invalidateSnapshot()
            } catch {
                ArcKitLog.append("runtime settings read failed: \(error.localizedDescription)")
                shutdown(); return
            }
            schedulePublish()
        }
    }

    private func refreshPermissionsAndServices() async {
        // 同一控制回包同时返回进程授权和功能恢复结果，不由两条业务连接分别发起授权。
        mouse.refreshPermissionAndHealth()
        await window.refreshPermissionAndHealthIfNeeded()
    }

    private func stateReply(requestID: UUID = UUID()) -> RuntimeHostReply {
        var states: [String: Data] = [:]
        states["window"] = try? RuntimeAgentIPCCodec.encode(window.snapshot())
        states["mouse"] = try? RuntimeAgentIPCCodec.encode(mouse.snapshot())
        return RuntimeHostReply(requestID: requestID, states: states, permissions: ProcessPermissions.snapshot(), sessionID: session.id, revision: appliedRevision)
    }
    private func schedulePublish() {
        guard publishTask == nil, !stopping, !reloading else { return }
        publishTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishTask = nil
            self.control.publish(self.stateReply())
        }
    }
    private func scheduleIdleExit() {
        idleTask?.cancel(); idleTask = nil
        guard !stopping, !reloading, !session.needsContinuousRuntime, activities == 0, !finder.hasActivity else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, !self.session.needsContinuousRuntime, self.activities == 0, !self.finder.hasActivity else { return }
            self.shutdown()
        }
    }
    private func shutdown() {
        stopping = true
        idleTask?.cancel(); publishTask?.cancel()
        window.stop(); mouse.stop()
        control.stop(); windowServer.stop(); mouseServer.stop(); finderServer.stop()
        ownerMonitor?.cancel()
        // Worker 监控父进程，并回收自身进程组；Host 不无限等待不响应的系统调用。
        exit(EXIT_SUCCESS)
    }
}
