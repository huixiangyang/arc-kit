import ArcKitPlatform
import ArcKitWindow
import Foundation


public final class WindowAgentXPCServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (WindowAgentRequest) async -> WindowAgentReply

    private let transport: RuntimeAgentXPCServer<WindowAgentRequest, WindowAgentReply>

    public init(handler: @escaping Handler) {
        transport = RuntimeAgentXPCServer(
            serviceName: ArcKitConstants.windowRuntimeMachServiceName,
            logLabel: "window",
            handler: handler,
            validateRequest: { try $0.validate() },
            validateReply: { try $0.validate(operation: $1.operation) },
            makeFailureReply: { WindowAgentReply(requestID: $0, errorMessage: $1) }
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
