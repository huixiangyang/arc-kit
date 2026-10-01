import Foundation

/// 一个客户端最多一个在途请求，保证设置更新以及“捕获目标 → 执行动作”的因果顺序。
/// 仅过滤迟到回包无法阻止 Agent 先应用新设置、再应用旧设置。
@MainActor
public final class RuntimeAgentRequestChannel<Request: RuntimeAgentRequestProtocol, Reply: RuntimeAgentReplyProtocol> {
    public typealias Completion = RuntimeAgentXPCClient<Request, Reply>.Completion
    public typealias Sender = (Request, @escaping Completion) -> Void

    private let sender: Sender
    private var pending: [(Request, Completion)] = []
    private var activeID: UUID?
    private var activeCompletion: Completion?

    public init(sender: @escaping Sender) {
        self.sender = sender
    }

    public func send(_ request: Request, completion: @escaping Completion) {
        guard pending.count < 64 else {
            completion(.failure(.connectionFailed(L10n.string(.Platform.requestRequestQueueFullRetryLater))))
            return
        }
        pending.append((request, completion))
        drain()
    }

    /// 先移除所有权，再回调取消；迟到的传输回包不能继续排队动作或重复完成请求。
    public func cancelAll() {
        let active = activeCompletion
        let queued = pending
        activeID = nil
        activeCompletion = nil
        pending.removeAll()
        let error = RuntimeAgentIPCError.connectionFailed(L10n.string(.Platform.requestRuntimeSessionEndedConfigurationChanged))
        active?(.failure(error))
        for (_, completion) in queued { completion(.failure(error)) }
    }

    private func drain() {
        guard activeID == nil, !pending.isEmpty else { return }
        let (request, completion) = pending.removeFirst()
        guard request.deadline > Date() else {
            completion(.failure(.requestExpired))
            drain()
            return
        }
        let token = UUID()
        activeID = token
        activeCompletion = completion
        sender(request) { [weak self] result in
            guard let self, self.activeID == token else { return }
            self.activeID = nil
            self.activeCompletion = nil
            completion(result)
            self.drain()
        }
    }
}
