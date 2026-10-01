import ArcKitWindow
import ArcKitPlatform
import Foundation

@MainActor
final class WindowAgentXPCClient {
    typealias Completion = @MainActor @Sendable (Result<WindowAgentReply, RuntimeAgentIPCError>) -> Void

    private let transport = RuntimeAgentXPCClient<WindowAgentRequest, WindowAgentReply>(
        serviceName: ArcKitConstants.windowRuntimeMachServiceName,
        expectedBundlePath: ArcKitConstants.installedRuntimeHostPath,
        expectedBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier,
        queueLabel: "com.archalo.arckit.runtime-host.window-client",
        validateReply: { reply, request in
            try reply.validate(operation: request.operation)
        }
    )

    private lazy var channel = RuntimeAgentRequestChannel<WindowAgentRequest, WindowAgentReply>(
        sender: { [transport] request, completion in transport.send(request, completion: completion) }
    )

    init() {}

    func send(_ request: WindowAgentRequest, completion: @escaping Completion) {
        channel.send(request, completion: completion)
    }

    func disconnect() {
        channel.cancelAll()
        transport.disconnect()
    }
}
