import ArcKitFinder
import ArcKitPlatform
import Foundation

struct FinderCommandDelivery: Sendable {
    typealias Completion = @MainActor @Sendable (
        Result<FinderCommandAcceptance, FinderAgentSecureIPCError>
    ) -> Void
    typealias CommandSender = @Sendable (
        FinderCommandRequest,
        @escaping Completion
    ) throws -> Void

    var commandSender: CommandSender

    static let live = FinderCommandDelivery { request, completion in
        FinderAgentSecureIPCClient.shared.submitCommand(request) { result in
            switch result {
            case let .success(reply):
                guard let acceptance = reply.commandAcceptance else {
                    completion(.failure(.malformedReply))
                    return
                }
                completion(.success(acceptance))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func enqueue(_ request: FinderCommandRequest, completion: @escaping Completion) throws {
        ArcKitLog.append(
            "extension secure enqueue start id=\(request.id.uuidString) kind=\(request.kind.rawValue) " +
            "targetPath=\(request.targetPath ?? "-") context=\(request.context.diagnosticDescription)"
        )
        do {
            try commandSender(request, completion)
            ArcKitLog.append("extension secure command sent awaiting reply id=\(request.id.uuidString)")
        } catch {
            ArcKitLog.append(
                "extension secure command send failed id=\(request.id.uuidString) error=\(error.localizedDescription)"
            )
            throw error
        }
    }
}

/// 通过安全 XPC 的直接响应判断命令是否被当前安装的 Agent 接收。
///
/// 仍保留有界超时，但不再监听任何可由同用户进程伪造的分布式回执。
@MainActor
final class FinderCommandAcknowledgementCenter {
    typealias FailureHandler = @MainActor (_ requestID: UUID, _ detail: String) -> Void

    static let shared = FinderCommandAcknowledgementCenter(
        timeout: 1.5,
        requireInstalledAgentIdentity: true,
        failureHandler: { requestID, detail in
            FinderUserPromptService.feedback(
                title: L10n.string(.FinderExtension.queueNoResponse),
                message: L10n.string(.FinderExtension.queueNotAcknowledged(String(describing: requestID.uuidString), String(describing: detail)))
            )
        }
    )

    private let timeoutNanoseconds: UInt64
    private let requireInstalledAgentIdentity: Bool
    private let failureHandler: FailureHandler
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        timeout: TimeInterval,
        requireInstalledAgentIdentity: Bool,
        failureHandler: @escaping FailureHandler
    ) {
        timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        self.requireInstalledAgentIdentity = requireInstalledAgentIdentity
        self.failureHandler = failureHandler
    }

    func deliver(
        _ request: FinderCommandRequest,
        delivery: FinderCommandDelivery = .live
    ) throws {
        track(request.id)
        do {
            try delivery.enqueue(request) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(acceptance):
                    _ = self.acknowledge(acceptance)
                case let .failure(error):
                    self.reject(request.id, error: error)
                }
            }
        } catch {
            cancel(request.id)
            throw error
        }
    }

    @discardableResult
    func acknowledge(_ acceptance: FinderCommandAcceptance) -> Bool {
        guard !requireInstalledAgentIdentity || acceptance.isInstalledFinderAgent else {
            ArcKitLog.append(
                "extension rejected secure command acceptance id=\(acceptance.requestID.uuidString) " +
                "agentPID=\(acceptance.agentProcessID) bundle=\(acceptance.agentBundleIdentifier) path=\(acceptance.agentBundlePath)"
            )
            reject(acceptance.requestID, error: .peerIdentityMismatch(L10n.string(.FinderExtension.queueIdentityMismatch)))
            return false
        }
        guard let task = timeoutTasks.removeValue(forKey: acceptance.requestID) else {
            return false
        }
        task.cancel()
        ArcKitLog.append(
            "extension secure command accepted id=\(acceptance.requestID.uuidString) agentPID=\(acceptance.agentProcessID)"
        )
        return true
    }

    func cancelAllForTesting() {
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
    }

    var pendingCountForTesting: Int {
        timeoutTasks.count
    }

    private func reject(_ requestID: UUID, error: FinderAgentSecureIPCError) {
        guard timeoutTasks.removeValue(forKey: requestID)?.cancel() != nil else { return }
        ArcKitLog.append(
            "extension secure command rejected id=\(requestID.uuidString) error=\(error.localizedDescription)"
        )
        failureHandler(requestID, error.localizedDescription)
    }

    private func track(_ requestID: UUID) {
        cancel(requestID)
        timeoutTasks[requestID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard timeoutTasks.removeValue(forKey: requestID) != nil else { return }
            ArcKitLog.append("extension secure command acceptance timeout id=\(requestID.uuidString)")
            failureHandler(requestID, L10n.string(.FinderExtension.queueTimeout))
        }
    }

    private func cancel(_ requestID: UUID) {
        timeoutTasks.removeValue(forKey: requestID)?.cancel()
    }
}

/// Finder 扩展侧命令投递器。扩展不直接执行副作用，只连接已安装 Agent 的 Mach service。
@MainActor
enum FinderCommandEnqueuer {
    static func enqueue(_ request: FinderCommandRequest) throws {
        try FinderCommandAcknowledgementCenter.shared.deliver(request)
    }
}
