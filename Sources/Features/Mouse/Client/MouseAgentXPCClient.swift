import ArcKitMouse
import ArcKitPlatform
import Foundation

@MainActor
final class MouseAgentXPCClient {
    typealias Completion = @MainActor @Sendable (Result<MouseAgentReply, RuntimeAgentIPCError>) -> Void

    private let transport = RuntimeAgentXPCClient<MouseAgentRequest, MouseAgentReply>(
        serviceName: ArcKitConstants.mouseRuntimeMachServiceName,
        expectedBundlePath: ArcKitConstants.installedRuntimeHostPath,
        expectedBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier,
        queueLabel: "com.archalo.arckit.runtime-host.mouse-client",
        validateReply: { reply, _ in try reply.validate() }
    )

    private lazy var channel = RuntimeAgentRequestChannel<MouseAgentRequest, MouseAgentReply>(
        sender: { [transport] request, completion in transport.send(request, completion: completion) }
    )

    init() {}

    func send(_ request: MouseAgentRequest, completion: @escaping Completion) {
        channel.send(request, completion: completion)
    }

    func disconnect() {
        channel.cancelAll()
        transport.disconnect()
    }
}
