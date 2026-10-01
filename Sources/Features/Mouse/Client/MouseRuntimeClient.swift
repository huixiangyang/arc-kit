import ArcKitPlatform
import ArcKitMouse
import Combine
import Foundation

/// 主应用持有的业务状态与命令客户端；不拥有后台注册或恢复策略。
@MainActor
public final class MouseRuntimeClient: ObservableObject {
    @Published public private(set) var snapshot = MouseAgentRuntimeSnapshot(
        lifecycle: .stopped,
        processID: 0,
        launchID: UUID(),
        accessibilityTrusted: false
    )

    @Published public private(set) var lastResponseAt: Date?

    typealias Sender = (MouseAgentRequest, @escaping MouseAgentXPCClient.Completion) -> Void
    private let sender: Sender
    private let disconnect: () -> Void
    private var context: RuntimeRequestContext?
    private var generation: UInt64 = 0
    private var replySequence = RuntimeReplySequence()

    public convenience init() {
        let client = MouseAgentXPCClient()
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
        publish(MouseAgentRuntimeSnapshot(lifecycle: .stopped, processID: 0, launchID: snapshot.launchID,
            accessibilityTrusted: snapshot.accessibilityTrusted))
    }

    func receive(_ state: MouseAgentRuntimeSnapshot) {
        guard context != nil else { return }
        replySequence.invalidatePendingReplies()
        lastResponseAt = Date()
        publish(state)
    }

    public func refresh() {
        guard context != nil else { return }
        send(MouseAgentRequest(operation: .fetchState, timeout: 0.8))
    }



    public func recordLocalFailure(_ message: String) {
        replySequence.invalidatePendingReplies()
        var candidate = snapshot
        candidate.lifecycle = .degraded
        candidate.lastRuntimeWarning = message
        candidate.lastFailureReason = message
        candidate.updatedAt = Date()
        publish(candidate)
    }

    private func send(_ request: MouseAgentRequest) {
        guard let context else { return }
        var request = request
        request.sessionID = context.sessionID
        request.revision = context.revision
        let expectedGeneration = generation
        let sequence = replySequence.beginRequest()
        sender(request) { [weak self] result in
            guard let self, self.context == context, self.generation == expectedGeneration else { return }
            guard self.replySequence.acceptReply(sequence: sequence) else { return }
            switch result {
            case let .success(reply):
                if let state = reply.state {
                    self.lastResponseAt = Date()
                    self.publish(state)
                }
            case let .failure(error):
                self.recordConnectionFailure(error.localizedDescription)
            }
        }
    }

    func recordConnectionFailure(_ message: String) {
        replySequence.invalidatePendingReplies()
        lastResponseAt = nil
        var candidate = snapshot
        candidate.lifecycle = .unavailable
        candidate.processID = 0
        candidate.accessibilityTrusted = false
        candidate.lastFailureReason = message
        candidate.updatedAt = Date()
        publish(candidate)
    }

    private func publish(_ candidate: MouseAgentRuntimeSnapshot) {
        guard !snapshot.hasSameRuntimeFacts(as: candidate) else { return }
        snapshot = candidate
    }
}
