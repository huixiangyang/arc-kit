import ArcKitFinder
import ArcKitPlatform
import Foundation
@preconcurrency import XPC

/// Finder 扩展侧安全 IPC 客户端。每次请求使用独立连接，并在解析响应前校验
/// Finder Agent 的 audit-token 代码身份、安装路径和当前安装包 cdhash。
final class FinderAgentSecureIPCClient: @unchecked Sendable {
    typealias ReplyCompletion = @MainActor @Sendable (Result<FinderAgentSecureIPCReply, FinderAgentSecureIPCError>) -> Void

    static let shared = FinderAgentSecureIPCClient()

    private let replyQueue = DispatchQueue(label: "com.archalo.arckit.finder-extension.secure-ipc", qos: .userInitiated)

    func submitCommand(
        _ request: FinderCommandRequest,
        completion: @escaping ReplyCompletion
    ) {
        do {
            perform(
                operation: .submitCommand,
                payload: try FinderAgentSecureIPCCodec.encode(request),
                completion: completion
            )
        } catch let error as FinderAgentSecureIPCError {
            FinderSecureIPCCompletionGate(completion: completion).finish(.failure(error))
        } catch {
            FinderSecureIPCCompletionGate(completion: completion).finish(
                .failure(.connectionFailed(error.localizedDescription))
            )
        }
    }

    func fetchSnapshot(completion: @escaping ReplyCompletion) {
        perform(operation: .fetchSnapshot, payload: nil, completion: completion)
    }

    func reportRuntimeState(
        _ state: FinderExtensionRuntimeState,
        completion: @escaping ReplyCompletion = { _ in }
    ) {
        do {
            perform(
                operation: .reportRuntimeState,
                payload: try FinderAgentSecureIPCCodec.encode(state),
                completion: completion
            )
        } catch let error as FinderAgentSecureIPCError {
            FinderSecureIPCCompletionGate(completion: completion).finish(.failure(error))
        } catch {
            FinderSecureIPCCompletionGate(completion: completion).finish(
                .failure(.connectionFailed(error.localizedDescription))
            )
        }
    }

    private func perform(
        operation: FinderAgentSecureIPCOperation,
        payload: Data?,
        completion: @escaping ReplyCompletion
    ) {
        let connection = xpc_connection_create_mach_service(
            ArcKitConstants.finderRuntimeMachServiceName,
            replyQueue,
            0
        )
        let connectionBox = FinderSecureIPCConnectionBox(connection)

        let completionGate = FinderSecureIPCCompletionGate(completion: completion)
        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            completionGate.finish(.failure(.connectionFailed(Self.errorDescription(event))))
            xpc_connection_cancel(connectionBox.connection)
        }
        xpc_connection_resume(connection)

        let timeout = FinderSecureIPCTimeoutBox {
            completionGate.finish(.failure(.connectionFailed(L10n.string(.FinderExtension.ipcRequestTimeout))))
            xpc_connection_cancel(connectionBox.connection)
        }
        timeout.schedule(on: replyQueue, after: 2)

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(
            message,
            FinderAgentSecureIPCCodec.operationKey,
            operation.rawValue
        )
        if let payload {
            // 编码器已拒绝空载荷；XPC 的 C 接口要求显式传入非空数据指针。
            payload.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(
                    message,
                    FinderAgentSecureIPCCodec.payloadKey,
                    bytes.baseAddress!,
                    bytes.count
                )
            }
        }

        xpc_connection_send_message_with_reply(connection, message, replyQueue) { response in
            timeout.cancel()
            defer { xpc_connection_cancel(connectionBox.connection) }
            do {
                if xpc_get_type(response) == XPC_TYPE_ERROR {
                    throw FinderAgentSecureIPCError.connectionFailed(Self.errorDescription(response))
                }
                try ArcKitXPCPeerIdentityVerifier.verify(
                    message: response,
                    expectedBundleURL: URL(fileURLWithPath: ArcKitConstants.installedRuntimeHostPath),
                    expectedBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier
                )
                guard let data = try Self.dataIfPresent(
                    in: response,
                    key: FinderAgentSecureIPCCodec.replyKey
                ) else {
                    throw FinderAgentSecureIPCError.malformedReply
                }
                let reply = try FinderAgentSecureIPCCodec.decodeReply(data)
                try reply.validate(for: operation)
                completionGate.finish(.success(reply))
            } catch let error as FinderAgentSecureIPCError {
                completionGate.finish(.failure(error))
            } catch {
                completionGate.finish(.failure(.malformedReply))
            }
        }
    }

    private static func dataIfPresent(in dictionary: xpc_object_t, key: String) throws -> Data? {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &length) else { return nil }
        guard length <= FinderAgentSecureIPCCodec.maximumPayloadBytes else {
            throw FinderAgentSecureIPCError.payloadTooLarge
        }
        return Data(bytes: bytes, count: length)
    }

    private static func errorDescription(_ error: xpc_object_t) -> String {
        guard let raw = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) else {
            return L10n.string(.FinderExtension.ipcUnknownXpcError)
        }
        return String(cString: raw)
    }
}

private final class FinderSecureIPCTimeoutBox: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(_ action: @escaping @Sendable () -> Void) {
        workItem = DispatchWorkItem(block: action)
    }

    func schedule(on queue: DispatchQueue, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class FinderSecureIPCConnectionBox: @unchecked Sendable {
    let connection: xpc_connection_t

    init(_ connection: xpc_connection_t) {
        self.connection = connection
    }
}

private final class FinderSecureIPCCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: FinderAgentSecureIPCClient.ReplyCompletion?

    init(completion: @escaping FinderAgentSecureIPCClient.ReplyCompletion) {
        self.completion = completion
    }

    func finish(_ result: Result<FinderAgentSecureIPCReply, FinderAgentSecureIPCError>) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return }
        Task { @MainActor in
            completion(result)
        }
    }
}
