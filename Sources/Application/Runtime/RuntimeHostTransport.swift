import ArcKitPlatform
import Foundation

@MainActor
protocol RuntimeHostTransport: AnyObject {
    typealias Completion = RuntimeAgentXPCClient<RuntimeHostRequest, RuntimeHostReply>.Completion
    var onState: ((RuntimeHostReply) -> Void)? { get set }
    var onInterruption: (() -> Void)? { get set }
    func send(_ request: RuntimeHostRequest, completion: @escaping Completion)
    func disconnect()
}

/// 一个应用运行实例拥有一个控制连接；主动断开后旧连接的排队通知失效。
@MainActor
final class RuntimeHostXPCTransport: RuntimeHostTransport {
    var onState: ((RuntimeHostReply) -> Void)?
    var onInterruption: (() -> Void)?
    private var client: RuntimeAgentXPCClient<RuntimeHostRequest, RuntimeHostReply>?
    private var generation: UInt64 = 0

    func send(_ request: RuntimeHostRequest, completion: @escaping Completion) {
        if client == nil { client = makeClient() }
        client?.send(request, completion: completion)
    }

    func disconnect() {
        generation &+= 1
        client?.disconnect()
        client = nil
    }

    private func makeClient() -> RuntimeAgentXPCClient<RuntimeHostRequest, RuntimeHostReply> {
        let expectedGeneration = generation
        return RuntimeAgentXPCClient(serviceName: ArcKitConstants.runtimeHostControlMachServiceName,
            expectedBundlePath: ArcKitConstants.installedRuntimeHostPath,
            expectedBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier,
            queueLabel: "com.archalo.arckit.runtime-host.control-client",
            eventHandler: { [weak self] reply in
                guard let self, self.generation == expectedGeneration else { return }
                self.onState?(reply)
            }, interruptionHandler: { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.onInterruption?()
            }, validateReply: { reply, request in
                guard reply.errorMessage != nil ||
                    (reply.sessionID == request.sessionID && reply.revision == request.revision) else {
                    throw RuntimeAgentIPCError.malformedReply
                }
            })
    }
}
