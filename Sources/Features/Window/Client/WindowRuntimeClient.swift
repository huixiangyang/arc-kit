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
        replySequence.invalidatePendingReplies()
        disconnect()
        // 新配置代次尚未收到后台确认，旧回包不能证明本次设置已生效。
        lastResponseAt = nil
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
        send(WindowAgentRequest(operation: .captureTarget, timeout: 3.5, captureApplication: application)) { reply in
            completion(reply?.targetCapture ?? .unavailable(reply?.errorMessage ?? L10n.string(.WindowSettings.connectionWindowServiceNotReadyReopenMenu)))
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
        completion: ((WindowAgentReply?) -> Void)? = nil
    ) {
        guard let context else { completion?(nil); return }
        var request = request
        request.sessionID = context.sessionID
        request.revision = context.revision
        let expectedGeneration = generation
        let sequence = replySequence.beginRequest()
        sender(request) { [weak self] result in
            var acceptedReply: WindowAgentReply?
            defer { completion?(acceptedReply) }
            guard let self, self.context == context, self.generation == expectedGeneration else { return }
            switch result {
            case let .success(reply):
                acceptedReply = reply
                if self.replySequence.acceptReply(sequence: sequence) {
                    self.apply(reply)
                }
            case let .failure(error):
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

    private func publish(_ candidate: WindowAgentRuntimeSnapshot) {
        guard !snapshot.hasSameRuntimeFacts(as: candidate) else { return }
        snapshot = candidate
    }
}
