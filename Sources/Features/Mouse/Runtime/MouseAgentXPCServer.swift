import ArcKitPlatform
import ArcKitMouse
import Foundation


public final class MouseAgentXPCServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (MouseAgentRequest) async -> MouseAgentReply

    private let transport: RuntimeAgentXPCServer<MouseAgentRequest, MouseAgentReply>

    public init(handler: @escaping Handler) {
        transport = RuntimeAgentXPCServer(
            serviceName: ArcKitConstants.mouseRuntimeMachServiceName,
            logLabel: "mouse",
            handler: handler,
            validateRequest: { try $0.validate() },
            validateReply: { reply, _ in try reply.validate() },
            makeFailureReply: { MouseAgentReply(requestID: $0, errorMessage: $1) }
        )
    }

    @discardableResult
    public func start() -> Bool {
        transport.start()
    }

    public func stop() {
        transport.stop()
    }
}
