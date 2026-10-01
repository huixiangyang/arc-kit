import ArcKitFinder
import ArcKitPlatform
import Foundation
@preconcurrency import XPC

/// Finder Agent 的 launchd Mach service。所有消息先用 XPC audit token 校验真实 Finder
/// 扩展代码，再进入命令、快照或运行态处理器。
public final class FinderAgentSecureIPCServer: @unchecked Sendable {
    public typealias CommandHandler = @MainActor @Sendable (Data) async -> FinderAgentSecureIPCReply
    public typealias SnapshotCompletion = @MainActor @Sendable (
        Result<FinderExtensionSnapshot, FinderAgentSecureIPCError>
    ) -> Void
    public typealias SnapshotProvider = @MainActor @Sendable (@escaping SnapshotCompletion) -> Void
    public typealias RuntimeStateHandler = @MainActor @Sendable (FinderExtensionRuntimeState) -> Bool

    private let commandHandler: CommandHandler
    private let snapshotProvider: SnapshotProvider
    private let runtimeStateHandler: RuntimeStateHandler
    private let listenerQueue = DispatchQueue(label: "com.archalo.arckit.runtime-host.finder", qos: .userInitiated)
    private var listener: xpc_connection_t?
    private var peers: [ObjectIdentifier: FinderAgentXPCObjectBox] = [:]
    private var pending: Set<ObjectIdentifier> = []

    public init(
        commandHandler: @escaping CommandHandler,
        snapshotProvider: @escaping SnapshotProvider,
        runtimeStateHandler: @escaping RuntimeStateHandler
    ) {
        self.commandHandler = commandHandler
        self.snapshotProvider = snapshotProvider
        self.runtimeStateHandler = runtimeStateHandler
    }

    @discardableResult
    public func start() -> Bool { listenerQueue.sync { startOnQueue() } }

    private func startOnQueue() -> Bool {
        guard listener == nil else { return true }
        let listener = xpc_connection_create_mach_service(
            ArcKitConstants.finderRuntimeMachServiceName,
            listenerQueue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        self.listener = listener
        let server = self
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
                ArcKitLog.append("secure ipc listener rejected non-connection event")
                return
            }
            server.accept(peer)
        }
        xpc_connection_resume(listener)
        ArcKitLog.append(
            "secure ipc listener started machService=\(ArcKitConstants.finderRuntimeMachServiceName)"
        )
        return true
    }

    public func stop() {
        listenerQueue.sync {
            if let listener { xpc_connection_cancel(listener) }
            listener = nil
            for peer in peers.values { xpc_connection_cancel(peer.object) }
            peers.removeAll()
        }
    }

    private func accept(_ peer: xpc_connection_t) {
        guard listener != nil, peers.count < 128 else { xpc_connection_cancel(peer); return }
        xpc_connection_set_target_queue(peer, listenerQueue)
        let peerBox = FinderAgentXPCObjectBox(peer)
        peers[ObjectIdentifier(peerBox)] = peerBox
        xpc_connection_set_event_handler(peer) { [weak self] message in
            guard let self else { return }
            if xpc_get_type(message) == XPC_TYPE_ERROR {
                self.peers.removeValue(forKey: ObjectIdentifier(peerBox))
            } else { self.receive(message, from: peerBox) }
        }
        xpc_connection_resume(peer)
    }

    private func receive(_ message: xpc_object_t, from peer: FinderAgentXPCObjectBox) {
        guard listener != nil, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        let messageBox = FinderAgentXPCObjectBox(message)
        do {
            try ArcKitXPCPeerIdentityVerifier.verify(
                message: message,
                expectedBundleURL: URL(fileURLWithPath: ArcKitConstants.installedFinderExtensionPath),
                expectedBundleIdentifier: ArcKitConstants.finderExtensionBundleIdentifier
            )
        } catch {
            ArcKitLog.append("secure ipc rejected peer error=\(error.localizedDescription)")
            respond(
                FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverFinderExtensionIdentityVerificationFailed)),
                message: messageBox,
                peer: peer
            )
            return
        }

        guard pending.count < 64 else {
            respond(FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverTooManyFinderRequestsRetryLater)), message: messageBox, peer: peer)
            return
        }
        pending.insert(ObjectIdentifier(messageBox))
        let deadline = Date().addingTimeInterval(5)

        guard let operationRaw = xpc_dictionary_get_string(
            message,
            FinderAgentSecureIPCCodec.operationKey
        ), let operation = FinderAgentSecureIPCOperation(rawValue: String(cString: operationRaw)) else {
            respond(
                FinderAgentSecureIPCReply(errorMessage: FinderAgentSecureIPCError.malformedMessage.localizedDescription),
                message: messageBox,
                peer: peer
            )
            return
        }

        let payload: Data?
        do {
            payload = try Self.dataIfPresent(in: message, key: FinderAgentSecureIPCCodec.payloadKey)
        } catch {
            respond(
                FinderAgentSecureIPCReply(errorMessage: error.localizedDescription),
                message: messageBox,
                peer: peer
            )
            return
        }
        switch operation {
        case .submitCommand:
            guard let payload else {
                respondMissingPayload(message: messageBox, peer: peer)
                return
            }
            let commandHandler = commandHandler
            Task { @MainActor in
                guard Date() < deadline else {
                    self.respond(FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverFinderRequestExpired)), message: messageBox, peer: peer)
                    return
                }
                let reply = await commandHandler(payload)
                self.respond(reply, message: messageBox, peer: peer)
            }

        case .fetchSnapshot:
            guard payload == nil else {
                respond(
                    FinderAgentSecureIPCReply(
                        errorMessage: FinderAgentSecureIPCError.unexpectedPayload.localizedDescription
                    ),
                    message: messageBox,
                    peer: peer
                )
                return
            }
            let snapshotProvider = snapshotProvider
            Task { @MainActor in
                guard Date() < deadline else {
                    self.respond(FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverFinderRequestExpired)), message: messageBox, peer: peer)
                    return
                }
                snapshotProvider { result in
                    switch result {
                    case let .success(snapshot):
                        self.respond(
                            FinderAgentSecureIPCReply(snapshot: snapshot),
                            message: messageBox,
                            peer: peer
                        )
                    case let .failure(error):
                        self.respond(
                            FinderAgentSecureIPCReply(errorMessage: error.localizedDescription),
                            message: messageBox,
                            peer: peer
                        )
                    }
                }
            }

        case .reportRuntimeState:
            guard let payload else {
                respondMissingPayload(message: messageBox, peer: peer)
                return
            }
            do {
                let state = try FinderAgentSecureIPCCodec.decode(FinderExtensionRuntimeState.self, from: payload)
                let runtimeStateHandler = runtimeStateHandler
                Task { @MainActor in
                guard Date() < deadline else {
                    self.respond(FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverFinderRequestExpired)), message: messageBox, peer: peer)
                    return
                }
                    let recorded = runtimeStateHandler(state)
                    self.respond(
                        FinderAgentSecureIPCReply(runtimeStateRecorded: recorded),
                        message: messageBox,
                        peer: peer
                    )
                }
            } catch {
                respond(
                    FinderAgentSecureIPCReply(errorMessage: L10n.string(.FinderActions.serverInvalidFinderExtensionRuntimeData(String(describing: error.localizedDescription)))),
                    message: messageBox,
                    peer: peer
                )
            }
        }
    }

    private func respondMissingPayload(
        message: FinderAgentXPCObjectBox,
        peer: FinderAgentXPCObjectBox
    ) {
        respond(
            FinderAgentSecureIPCReply(errorMessage: FinderAgentSecureIPCError.missingPayload.localizedDescription),
            message: message,
            peer: peer
        )
    }

    private func respond(
        _ response: FinderAgentSecureIPCReply,
        message: FinderAgentXPCObjectBox,
        peer: FinderAgentXPCObjectBox
    ) {
        listenerQueue.async {
            self.pending.remove(ObjectIdentifier(message))
            guard self.listener != nil else { return }
            self.respondOnQueue(response, message: message, peer: peer)
        }
    }

    private func respondOnQueue(_ response: FinderAgentSecureIPCReply, message: FinderAgentXPCObjectBox, peer: FinderAgentXPCObjectBox) {
        guard let reply = xpc_dictionary_create_reply(message.object) else {
            ArcKitLog.append("secure ipc could not create reply")
            return
        }
        do {
            let data = try FinderAgentSecureIPCCodec.encodeReply(response)
            // 编码器已拒绝空载荷；XPC 的 C 接口要求显式传入非空数据指针。
            data.withUnsafeBytes { bytes in
                xpc_dictionary_set_data(
                    reply,
                    FinderAgentSecureIPCCodec.replyKey,
                    bytes.baseAddress!,
                    bytes.count
                )
            }
            xpc_connection_send_message(peer.object, reply)
        } catch {
            ArcKitLog.append("secure ipc reply encode failed error=\(error.localizedDescription)")
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
}

private final class FinderAgentXPCObjectBox: @unchecked Sendable {
    let object: xpc_object_t

    init(_ object: xpc_object_t) {
        self.object = object
    }
}
