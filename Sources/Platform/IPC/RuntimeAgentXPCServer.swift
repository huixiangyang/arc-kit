import Foundation
@preconcurrency import XPC

/// 与业务协议无关的 Mach service 服务端。业务 target 负责提供严格的请求与响应校验。
public final class RuntimeAgentXPCServer<Request: RuntimeAgentRequestProtocol, Reply: RuntimeAgentReplyProtocol>: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (Request) async -> Reply
    public typealias RequestValidator = @Sendable (Request) throws -> Void
    public typealias ReplyValidator = @Sendable (Reply, Request) throws -> Void
    public typealias FailureReplyBuilder = @Sendable (UUID, String) -> Reply

    private let serviceName: String
    private let logLabel: String
    private let handler: Handler
    private let validateRequest: RequestValidator
    private let validateReply: ReplyValidator
    private let makeFailureReply: FailureReplyBuilder
    private let listenerQueue: DispatchQueue
    private var peers: [ObjectIdentifier: RuntimeAgentXPCObjectBox] = [:]
    private var connections: [ObjectIdentifier: RuntimeAgentXPCObjectBox] = [:]
    private var acceptedRequests: [UUID: Date] = [:]
    private var inFlight = 0
    private var listener: xpc_connection_t?

    public init(
        serviceName: String,
        logLabel: String,
        handler: @escaping Handler,
        validateRequest: @escaping RequestValidator,
        validateReply: @escaping ReplyValidator,
        makeFailureReply: @escaping FailureReplyBuilder
    ) {
        self.serviceName = serviceName
        self.logLabel = logLabel
        self.handler = handler
        self.validateRequest = validateRequest
        self.validateReply = validateReply
        self.makeFailureReply = makeFailureReply
        listenerQueue = DispatchQueue(label: "com.archalo.arckit.\(logLabel)-agent.xpc-server", qos: .userInitiated)
    }

    @discardableResult
    public func start() -> Bool { listenerQueue.sync { startOnQueue() } }

    private func startOnQueue() -> Bool {
        guard listener == nil else { return true }
        let created = xpc_connection_create_mach_service(
            serviceName,
            listenerQueue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        listener = created
        let server = self
        xpc_connection_set_event_handler(created) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            server.accept(peer)
        }
        xpc_connection_resume(created)
        ArcKitLog.append("\(logLabel) agent xpc listener started service=\(serviceName)")
        return true
    }

    public func stop() {
        listenerQueue.sync {
            if let listener { xpc_connection_cancel(listener) }
            self.listener = nil
            for peer in connections.values { xpc_connection_cancel(peer.object) }
            connections.removeAll()
            peers.removeAll()
        }
    }

    /// 只推送给已经完成主应用身份校验的连接。
    public func publish(_ response: Reply) {
        listenerQueue.async {
            guard let data = try? RuntimeAgentIPCCodec.encode(response) else { return }
            for peer in self.peers.values {
                let event = xpc_dictionary_create(nil, nil, 0)
                data.withUnsafeBytes { bytes in
                    xpc_dictionary_set_data(event, RuntimeAgentIPCCodec.replyKey, bytes.baseAddress, bytes.count)
                }
                xpc_connection_send_message(peer.object, event)
            }
        }
    }

    private func accept(_ peer: xpc_connection_t) {
        guard listener != nil, connections.count < 128 else { xpc_connection_cancel(peer); return }
        xpc_connection_set_target_queue(peer, listenerQueue)
        let peerBox = RuntimeAgentXPCObjectBox(peer)
        connections[ObjectIdentifier(peerBox)] = peerBox
        let server = self
        xpc_connection_set_event_handler(peer) { message in
            if xpc_get_type(message) == XPC_TYPE_ERROR {
                server.peers.removeValue(forKey: ObjectIdentifier(peerBox))
                server.connections.removeValue(forKey: ObjectIdentifier(peerBox))
            } else { server.receive(message, from: peerBox) }
        }
        xpc_connection_resume(peer)
    }

    private func receive(_ message: xpc_object_t, from peer: RuntimeAgentXPCObjectBox) {
        guard listener != nil, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        let messageBox = RuntimeAgentXPCObjectBox(message)
        do {
            try verifyMainApp(message)
            peers[ObjectIdentifier(peer)] = peer
            let data = try Self.data(in: message, key: RuntimeAgentIPCCodec.payloadKey)
            let request = try RuntimeAgentIPCCodec.decode(Request.self, from: data)
            try validateRequest(request)
            guard inFlight < 64 else { throw RuntimeAgentIPCError.connectionFailed(L10n.string(.Platform.serverTooManyBackgroundRequestsRetryLater)) }
            acceptedRequests = acceptedRequests.filter { $0.value > Date() }
            guard acceptedRequests[request.requestID] == nil, acceptedRequests.count < 512 else {
                throw RuntimeAgentIPCError.remoteFailure(L10n.string(.Platform.serverRequestAlreadyAcceptedTooManyRequests))
            }
            acceptedRequests[request.requestID] = request.deadline
            inFlight += 1
            let handler = handler
            Task { @MainActor in
                defer { self.listenerQueue.async { self.inFlight -= 1 } }
                let reply: Reply
                do {
                    // 请求排队之后再次检查时限，禁止执行已超时的副作用。
                    try self.validateRequest(request)
                    let handledReply = await handler(request)
                    guard handledReply.requestID == request.requestID else {
                        throw RuntimeAgentIPCError.malformedReply
                    }
                    try self.validateReply(handledReply, request)
                    reply = handledReply
                } catch {
                    reply = self.makeFailureReply(
                        request.requestID,
                        L10n.string(.Platform.serverAgentInternalResponseViolatesProtocol(String(describing: error.localizedDescription)))
                    )
                }
                self.respond(reply, message: messageBox, peer: peer)
            }
        } catch {
            let requestID = (try? Self.data(in: message, key: RuntimeAgentIPCCodec.payloadKey))
                .flatMap { try? RuntimeAgentIPCCodec.decode(Request.self, from: $0).requestID }
                ?? UUID()
            respond(
                makeFailureReply(requestID, error.localizedDescription),
                message: messageBox,
                peer: peer
            )
            ArcKitLog.append("\(logLabel) agent xpc rejected request error=\(error.localizedDescription)")
        }
    }

    private func verifyMainApp(_ message: xpc_object_t) throws {
#if DEBUG
        if ProcessInfo.processInfo.environment["ARC_KIT_ALLOW_UNVERIFIED_LOCAL_IPC"] == "1" {
            return
        }
#endif
        try ArcKitXPCPeerIdentityVerifier.verify(
            message: message,
            expectedBundleURL: URL(fileURLWithPath: ArcKitConstants.installedAppPath),
            expectedBundleIdentifier: ArcKitConstants.appBundleIdentifier
        )
    }

    private func respond(
        _ response: Reply,
        message: RuntimeAgentXPCObjectBox,
        peer: RuntimeAgentXPCObjectBox
    ) {
        guard let reply = xpc_dictionary_create_reply(message.object) else { return }
        do {
            let encoded = try RuntimeAgentIPCCodec.encode(response)
            encoded.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(
                    reply,
                    RuntimeAgentIPCCodec.replyKey,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            xpc_connection_send_message(peer.object, reply)
        } catch {
            ArcKitLog.append("\(logLabel) agent xpc reply encode failed error=\(error.localizedDescription)")
        }
    }

    private static func data(in dictionary: xpc_object_t, key: String) throws -> Data {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &length) else {
            throw RuntimeAgentIPCError.missingPayload
        }
        guard length <= RuntimeAgentIPCCodec.maximumPayloadBytes else {
            throw RuntimeAgentIPCError.payloadTooLarge
        }
        return Data(bytes: bytes, count: length)
    }
}

private final class RuntimeAgentXPCObjectBox: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
