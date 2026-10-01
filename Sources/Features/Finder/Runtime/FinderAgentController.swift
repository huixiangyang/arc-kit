import ArcKitFinder
import ArcKitPlatform
import Foundation

/// 统一 Runtime Host 中的 Finder 会话：验证命令接收、合并快照构建并报告活动状态。
@MainActor
public final class FinderAgentController {
    public typealias SnapshotBuilder = @Sendable (FinderRuntimeSettings) -> FinderExtensionSnapshot
    public typealias SnapshotFetchCompletion = @MainActor @Sendable (
        Result<FinderExtensionSnapshot, FinderAgentSecureIPCError>
    ) -> Void

    private let admissionStore: FinderCommandAdmissionStore?
    private let processor: FinderCommandProcessor
    private let settingsProvider: @Sendable () -> FinderRuntimeSettings
    private let extensionRuntimeStateStore: FinderExtensionRuntimeStateStore
    private let snapshotBuilder: SnapshotBuilder
    private var snapshotResponseTask: Task<Void, Never>?
    private var snapshotWaiters: [SnapshotFetchCompletion] = []
    private var cachedSnapshot: (Date, FinderExtensionSnapshot)?
    public var activityDidChange: (() -> Void)?
    public var hasActivity: Bool { snapshotResponseTask != nil || processor.hasActiveCommands }
    private var snapshotGeneration = 0
    public func invalidateSnapshot() { snapshotGeneration += 1; cachedSnapshot = nil }

    public init(
        processor: FinderCommandProcessor? = nil,
        admissionStore: FinderCommandAdmissionStore? = nil,
        settingsProvider: @escaping @Sendable () -> FinderRuntimeSettings,
        extensionRuntimeStateStore: FinderExtensionRuntimeStateStore = FinderExtensionRuntimeStateStore(),
        snapshotBuilder: @escaping SnapshotBuilder = { settings in
            FinderExtensionSnapshot.make(
                settings: settings,
                applicationAvailability: { FavoriteApplicationAvailabilityResolver.isAvailable($0) }
            )
        }
    ) {
        self.admissionStore = admissionStore
        self.processor = processor ?? FinderCommandProcessor(settingsProvider: settingsProvider)
        self.settingsProvider = settingsProvider
        self.extensionRuntimeStateStore = extensionRuntimeStateStore
        self.snapshotBuilder = snapshotBuilder
        self.processor.activityDidChange = { [weak self] in self?.activityDidChange?() }
    }

    /// 仅供已通过 XPC audit-token 身份校验的服务调用。先生成接收回执，再把执行排入
    /// 主线程下一轮，避免长文件操作阻塞 XPC 接收确认。
    public func acceptSecureCommandData(_ data: Data) -> FinderAgentSecureIPCReply {
        do {
            let request = try FinderAgentSecureIPCCodec.decode(FinderCommandRequest.self, from: data)
            ArcKitLog.append(
                "agent received secure finder command id=\(request.id.uuidString) kind=\(request.kind.rawValue)"
            )
            guard !processor.hasActiveCommands else { throw RuntimeAgentIPCError.remoteFailure(L10n.string(.FinderActions.agentFinderActionAlreadyRunningTry)) }
            try admissionStore?.accept(request)
            let acceptance = FinderCommandAcceptance(
                requestID: request.id,
                agentProcessID: ProcessInfo.processInfo.processIdentifier,
                agentBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                agentBundlePath: Bundle.main.bundleURL.path
            )
            processor.process(request)
            return FinderAgentSecureIPCReply(commandAcceptance: acceptance)
        } catch {
            ArcKitLog.append("agent failed to decode secure finder command error=\(error.localizedDescription)")
            return FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.agentInvalidFinderCommandData(String(describing: error.localizedDescription))))
        }
    }

    /// 所有安全快照请求共享一个构建；主 App 设置提交时会使缓存失效。
    public func fetchLatestSnapshot(completion: @escaping SnapshotFetchCompletion) {
        if let cachedSnapshot, Date().timeIntervalSince(cachedSnapshot.0) < 2 {
            completion(.success(cachedSnapshot.1)); return
        }
        guard snapshotWaiters.count < 64 else {
            completion(.failure(.connectionFailed(L10n.string(.FinderActions.agentTooManyMenuRequestsRetryLater)))); return
        }
        snapshotWaiters.append(completion)
        guard snapshotResponseTask == nil else { return }
        let settingsProvider = settingsProvider
        let snapshotBuilder = snapshotBuilder
        snapshotResponseTask = Task { [weak self] in
            guard let self else { return }
            var generation: Int
            var snapshot: FinderExtensionSnapshot
            repeat {
                generation = self.snapshotGeneration
                snapshot = await Task.detached(priority: .utility) { snapshotBuilder(settingsProvider()) }.value
            } while generation != self.snapshotGeneration
            self.cachedSnapshot = (Date(), snapshot)
            let waiters = self.snapshotWaiters
            self.snapshotWaiters.removeAll()
            self.snapshotResponseTask = nil
            for waiter in waiters { waiter(.success(snapshot)) }
            self.activityDidChange?()
        }
        activityDidChange?()
    }

    @discardableResult
    public func recordFinderExtensionRuntimeState(_ state: FinderExtensionRuntimeState) -> Bool {
        do {
            try extensionRuntimeStateStore.record(state)
            ArcKitLog.append(
                "agent recorded finder extension runtime state event=\(state.event.rawValue) pid=\(state.processID) " +
                "directoryURLs count=\(state.observedDirectoryPaths.count) menuItems=\(state.lastMenuBuild?.itemCount ?? -1)"
            )
            return true
        } catch {
            ArcKitLog.append("agent rejected finder extension runtime state error=\(error.localizedDescription)")
            return false
        }
    }
}
