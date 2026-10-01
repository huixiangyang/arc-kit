import Foundation
@preconcurrency import XPC

/// 与业务协议无关的有界 XPC 客户端。请求/响应结构和校验规则由具体业务模块注入。
public final class RuntimeAgentXPCClient<Request: RuntimeAgentRequestProtocol, Reply: RuntimeAgentReplyProtocol>: @unchecked Sendable {
    public typealias Completion = @MainActor @Sendable (Result<Reply, RuntimeAgentIPCError>) -> Void
    public typealias ReplyValidator = @Sendable (Reply, Request) throws -> Void

    private var connectionBox: RuntimeAgentXPCConnectionBox?
    private let eventHandler: (@MainActor @Sendable (Reply) -> Void)?
    private let interruptionHandler: (@MainActor @Sendable () -> Void)?
    private let serviceName: String
    private let expectedBundlePath: String
    private let expectedBundleIdentifier: String
    private let replyQueue: DispatchQueue
    private let validateReply: ReplyValidator

    public init(
        serviceName: String,
        expectedBundlePath: String,
        expectedBundleIdentifier: String,
        queueLabel: String,
        eventHandler: (@MainActor @Sendable (Reply) -> Void)? = nil,
        interruptionHandler: (@MainActor @Sendable () -> Void)? = nil,
        validateReply: @escaping ReplyValidator
    ) {
        self.eventHandler = eventHandler
        self.interruptionHandler = interruptionHandler
        self.serviceName = serviceName
        self.expectedBundlePath = expectedBundlePath
        self.expectedBundleIdentifier = expectedBundleIdentifier
        replyQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.validateReply = validateReply
    }

    deinit { if let connectionBox { xpc_connection_cancel(connectionBox.connection) } }

    public func send(_ request: Request, completion: @escaping Completion) {
        let gate = RuntimeAgentReplyGate<Reply>(completion: completion)
        do {
            let payload = try RuntimeAgentIPCCodec.encode(request)
            replyQueue.async { self.perform(request: request, payload: payload, gate: gate) }
        } catch let error as RuntimeAgentIPCError {
            gate.finish(.failure(error))
        } catch {
            gate.finish(.failure(.connectionFailed(error.localizedDescription)))
        }
    }

    private func perform(
        request: Request,
        payload: Data,
        gate: RuntimeAgentReplyGate<Reply>
    ) {
        guard request.deadline > Date() else { gate.finish(.failure(.requestExpired)); return }
        let connectionBox = connectedTransport()

        let timeout = max(0.1, request.deadline.timeIntervalSinceNow)
        let timeoutBox = RuntimeAgentTimeoutBox {
            gate.finish(.failure(.connectionFailed(L10n.string(.Platform.ipcRequestTimeout))))
        }
        timeoutBox.schedule(on: replyQueue, after: timeout)

        let message = xpc_dictionary_create(nil, nil, 0)
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                message,
                RuntimeAgentIPCCodec.payloadKey,
                bytes.baseAddress,
                bytes.count
            )
        }
        xpc_connection_send_message_with_reply(connectionBox.connection, message, replyQueue) { response in
            timeoutBox.cancel()
            do {
                if xpc_get_type(response) == XPC_TYPE_ERROR {
                    throw RuntimeAgentIPCError.connectionFailed(Self.errorDescription(response))
                }
                try self.verifyAgent(response)
                let data = try Self.data(in: response, key: RuntimeAgentIPCCodec.replyKey)
                let reply = try RuntimeAgentIPCCodec.decode(Reply.self, from: data)
                guard reply.requestID == request.requestID else {
                    throw RuntimeAgentIPCError.malformedReply
                }
                try self.validateReply(reply, request)
                if let errorMessage = reply.errorMessage {
                    throw RuntimeAgentIPCError.remoteFailure(errorMessage)
                }
                gate.finish(.success(reply))
            } catch let error as RuntimeAgentIPCError {
                gate.finish(.failure(error))
            } catch {
                gate.finish(.failure(.malformedReply))
            }
        }
    }

    public func disconnect() {
        replyQueue.async {
            let old = self.connectionBox
            self.connectionBox = nil
            if let old { xpc_connection_cancel(old.connection) }
        }
    }

    private func connectedTransport() -> RuntimeAgentXPCConnectionBox {
        if let connectionBox { return connectionBox }
        let connection = xpc_connection_create_mach_service(serviceName, replyQueue, 0)
        let box = RuntimeAgentXPCConnectionBox(connection)
        connectionBox = box
        xpc_connection_set_event_handler(connection) { [weak self, weak box] event in
            guard let self, let box, self.connectionBox === box else { return }
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self.connectionBox = nil
                xpc_connection_cancel(box.connection)
                if let handler = self.interruptionHandler { Task { @MainActor in handler() } }
            } else if xpc_get_type(event) == XPC_TYPE_DICTIONARY, let handler = self.eventHandler {
                do {
                    try self.verifyAgent(event)
                    let data = try Self.data(in: event, key: RuntimeAgentIPCCodec.replyKey)
                    let reply = try RuntimeAgentIPCCodec.decode(Reply.self, from: data)
                    Task { @MainActor in handler(reply) }
                } catch { ArcKitLog.append("runtime state event rejected: \(error.localizedDescription)") }
            }
        }
        xpc_connection_resume(connection)
        return box
    }

    private func verifyAgent(_ message: xpc_object_t) throws {
#if DEBUG
        if ProcessInfo.processInfo.environment["ARC_KIT_ALLOW_UNVERIFIED_LOCAL_IPC"] == "1" {
            return
        }
#endif
        try ArcKitXPCPeerIdentityVerifier.verify(
            message: message,
            expectedBundleURL: URL(fileURLWithPath: expectedBundlePath),
            expectedBundleIdentifier: expectedBundleIdentifier
        )
    }

    private static func data(in dictionary: xpc_object_t, key: String) throws -> Data {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &length) else {
            throw RuntimeAgentIPCError.malformedReply
        }
        guard length <= RuntimeAgentIPCCodec.maximumPayloadBytes else {
            throw RuntimeAgentIPCError.payloadTooLarge
        }
        return Data(bytes: bytes, count: length)
    }

    private static func errorDescription(_ error: xpc_object_t) -> String {
        guard let raw = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) else {
            return L10n.string(.Platform.ipcUnknownXpcError)
        }
        return String(cString: raw)
    }
}

private final class RuntimeAgentTimeoutBox: @unchecked Sendable {
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

private final class RuntimeAgentXPCConnectionBox: @unchecked Sendable {
    let connection: xpc_connection_t

    init(_ connection: xpc_connection_t) {
        self.connection = connection
    }
}

private final class RuntimeAgentReplyGate<Reply: RuntimeAgentReplyProtocol>: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (Result<Reply, RuntimeAgentIPCError>) -> Void

    private let lock = NSLock()
    private var completion: Completion?

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    func finish(_ result: Result<Reply, RuntimeAgentIPCError>) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        guard let completion else { return }
        Task { @MainActor in completion(result) }
    }
}
