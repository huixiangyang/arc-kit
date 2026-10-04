import ArcKitPlatform
import ArcKitWindow
import Combine
import Foundation

/// 主应用持有的业务状态与命令客户端；不拥有后台注册或恢复策略。
@MainActor
public final class WindowRuntimeClient: ObservableObject {
    @Published public private(set) var snapshot = WindowAgentRuntimeSnapshot(
        lifecycle: .stopped,
        processID: 0,
        launchID: UUID(),
        accessibilityTrusted: false,
        accessibilityOperational: false
    )

    @Published public private(set) var lastResponseAt: Date?

    typealias Sender = (WindowAgentRequest, @escaping WindowAgentXPCClient.Completion) -> Void
    private let sender: Sender
    private let disconnect: () -> Void
    private var context: RuntimeRequestContext?
    private var generation: UInt64 = 0
    private var replySequence = RuntimeReplySequence()
    private var latestSceneReply: (launchID: UUID, report: WindowSceneExecutionReport)?

    public convenience init() {
        let client = WindowAgentXPCClient()
        self.init(sender: { client.send($0, completion: $1) }, disconnect: { client.disconnect() })
    }

    init(sender: @escaping Sender, disconnect: @escaping () -> Void) {
        self.sender = sender
        self.disconnect = disconnect
    }

    /// 会话上下文只由应用组合根的协调器设置；状态代理不反向查询协调器。
    func configure(context: RuntimeRequestContext?) {
        guard self.context != context || context == nil else { return }
        self.context = context
        generation &+= 1
        latestSceneReply = nil
        replySequence.invalidatePendingReplies()
        disconnect()
        // 新配置代次尚未收到后台确认，旧回包不能证明本次设置已生效。
        lastResponseAt = nil
        var pending = snapshot
        pending.lastSceneResult = nil
        publish(pending)
        guard context == nil else { return }
        publish(WindowAgentRuntimeSnapshot(lifecycle: .stopped, processID: 0, launchID: snapshot.launchID,
            accessibilityTrusted: snapshot.accessibilityTrusted, accessibilityOperational: false))
    }

    func receive(_ state: WindowAgentRuntimeSnapshot) {
        guard context != nil else { return }
        replySequence.invalidatePendingReplies()
        lastResponseAt = Date()
        publish(state)
    }

    public func refresh() {
        guard context != nil else { return }
        send(WindowAgentRequest(operation: .fetchState, timeout: 0.8), recordsConnectionFailure: true)
    }

    public func captureWindowTarget(application: AppConfigurationCandidate? = nil, completion: @escaping (WindowTargetCaptureResult) -> Void) {
        // 断线或会话变化也要结束等待；业务拒绝保留原原因，不能变成可执行令牌。
        send(WindowAgentRequest(operation: .captureTarget, timeout: 3.5, captureApplication: application)) { reply, errorMessage in
            completion(reply?.targetCapture ?? .unavailable(reply?.errorMessage ?? errorMessage ?? L10n.string(.WindowSettings.connectionWindowServiceNotReadyReopenMenu)))
        }
    }

    public func fetchSceneInventory(completion: @escaping (Result<WindowSceneInventory, WindowSceneClientError>) -> Void) {
        send(WindowAgentRequest(operation: .sceneInventory, timeout: 13)) { [weak self] reply, errorMessage in
            if let inventory = reply?.sceneInventory, let launchID = reply?.state?.launchID,
               launchID == self?.snapshot.launchID, inventory.hostLaunchID == launchID {
                completion(.success(inventory))
            } else {
                completion(.failure(WindowSceneClientError(message: reply?.errorMessage ?? errorMessage ?? L10n.string(.WindowSettings.scenesConnectionFailed))))
            }
        }
    }

    public func applyScene(id: UUID, completion: @escaping (Result<WindowSceneExecutionReport, WindowSceneClientError>) -> Void) {
        sendSceneRequest(WindowAgentRequest(operation: .applyScene, timeout: 35, sceneID: id), completion: completion)
    }

    public func undoScene(token: UUID, completion: @escaping (Result<WindowSceneExecutionReport, WindowSceneClientError>) -> Void) {
        sendSceneRequest(WindowAgentRequest(operation: .undoScene, timeout: 35, undoToken: token), completion: completion)
    }

    private func sendSceneRequest(_ request: WindowAgentRequest, completion: @escaping (Result<WindowSceneExecutionReport, WindowSceneClientError>) -> Void) {
        // 只发送已提交场景的 ID；布局与匹配规则由 Host 从同一设置版本读取。
        send(request) { [weak self] reply, errorMessage in
            if let report = reply?.sceneResult {
                guard let self, let launchID = reply?.state?.launchID, launchID == self.snapshot.launchID else {
                    completion(.failure(WindowSceneClientError(message: L10n.string(.WindowSettings.connectionWindowActionSSessionEnded))))
                    return
                }
                // 批量动作可能比后发的健康查询晚完成。只合并当前 Host 的最新报告，
                // 不让请求序号丢掉真实结果，也不覆盖更晚回包中的生命周期状态。
                if self.latestSceneReply?.launchID != launchID ||
                    (self.latestSceneReply?.report.completedAt ?? .distantPast) <= report.completedAt {
                    self.latestSceneReply = (launchID, report)
                    self.publish(self.snapshot)
                }
                completion(.success(report))
            } else {
                completion(.failure(WindowSceneClientError(message: reply?.errorMessage ?? errorMessage ?? L10n.string(.WindowSettings.scenesConnectionFailed))))
            }
        }
    }



    public func perform(
        _ action: WindowLayoutAction,
        targetID: UUID,
        completion: ((WindowManagementResult) -> Void)? = nil
    ) {
        guard let context else { completion?(.init(succeeded: false, userMessage: L10n.string(.WindowSettings.connectionWindowManagementOff))); return }
        var request = WindowAgentRequest(operation: .performAction, action: action, targetID: targetID)
        request.sessionID = context.sessionID
        request.revision = context.revision
        let expectedGeneration = generation
        let sequence = replySequence.beginRequest()
        sender(request) { [weak self] result in
            guard let self, self.context == context, self.generation == expectedGeneration else {
                completion?(.init(succeeded: false, userMessage: L10n.string(.WindowSettings.connectionWindowActionSSessionEnded)))
                return
            }
            switch result {
            case let .success(reply):
                if self.replySequence.acceptReply(sequence: sequence) {
                    self.apply(reply)
                }
                if let result = reply.result {
                    completion?(result)
                }
            case let .failure(error):
                let failure = WindowManagementResult(
                    succeeded: false,
                    userMessage: L10n.string(.WindowSettings.connectionUnavailableReason(String(describing: error.localizedDescription)))
                )
                if self.replySequence.acceptReply(sequence: sequence) {
                    self.recordConnectionFailure(error, windowResult: failure)
                }
                completion?(failure)
            }
        }
    }

    private func send(
        _ request: WindowAgentRequest,
        recordsConnectionFailure: Bool = true,
        completion: ((WindowAgentReply?, String?) -> Void)? = nil
    ) {
        guard let context else { completion?(nil, L10n.string(.WindowSettings.connectionWindowManagementOff)); return }
        var request = request
        request.sessionID = context.sessionID
        request.revision = context.revision
        let expectedGeneration = generation
        let sequence = replySequence.beginRequest()
        sender(request) { [weak self] result in
            var acceptedReply: WindowAgentReply?
            var errorMessage: String?
            defer { completion?(acceptedReply, errorMessage) }
            guard let self, self.context == context, self.generation == expectedGeneration else {
                errorMessage = L10n.string(.WindowSettings.connectionWindowActionSSessionEnded)
                return
            }
            switch result {
            case let .success(reply):
                acceptedReply = reply
                if self.replySequence.acceptReply(sequence: sequence) {
                    self.apply(reply)
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
                if recordsConnectionFailure,
                   self.replySequence.acceptReply(sequence: sequence) {
                    self.recordConnectionFailure(error)
                }
            }
        }
    }

    private func apply(_ reply: WindowAgentReply) {
        if let state = reply.state {
            lastResponseAt = Date()
            publish(state)
        } else if let result = reply.result {
            var candidate = snapshot
            candidate.lastResult = result
            candidate.updatedAt = Date()
            publish(candidate)
        }
    }

    private func recordConnectionFailure(
        _ error: RuntimeAgentIPCError,
        windowResult: WindowManagementResult? = nil
    ) {
        lastResponseAt = nil
        var candidate = snapshot
        candidate.lifecycle = .unavailable
        candidate.processID = 0
        candidate.accessibilityTrusted = false
        candidate.accessibilityOperational = false
        candidate.hotKeyRegisteredCount = 0
        candidate.dragSnapState = .stopped
        candidate.lastResult = windowResult ?? WindowManagementResult(
            succeeded: false,
            userMessage: error.localizedDescription
        )
        candidate.updatedAt = Date()
        publish(candidate)
    }

    func markConnectionUnavailable(_ message: String) {
        replySequence.invalidatePendingReplies()
        recordConnectionFailure(.connectionFailed(message))
    }

    private func publish(_ value: WindowAgentRuntimeSnapshot) {
        var candidate = value
        if latestSceneReply?.launchID != candidate.launchID { latestSceneReply = nil }
        if let report = candidate.lastSceneResult,
           report.completedAt >= (latestSceneReply?.report.completedAt ?? .distantPast) {
            // 快捷键触发的报告也参与去旧，避免后到的健康快照把结果倒退。
            latestSceneReply = (candidate.launchID, report)
        }
        if let latestSceneReply,
           (candidate.lastSceneResult?.completedAt ?? .distantPast) < latestSceneReply.report.completedAt {
            candidate.lastSceneResult = latestSceneReply.report
        }
        guard !snapshot.hasSameRuntimeFacts(as: candidate) else { return }
        snapshot = candidate
    }
}
