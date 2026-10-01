import Foundation

/// 主应用显式传递的命令上下文；业务客户端不自行读取全局会话文件。
public struct RuntimeRequestContext: Equatable, Sendable {
    public let sessionID: UUID
    public let revision: UInt64

    public init(sessionID: UUID, revision: UInt64) {
        self.sessionID = sessionID
        self.revision = revision
    }
}

public struct RuntimeHostRequest: RuntimeAgentRequestProtocol {
    public static let protocolVersion: UInt16 = 2
    public let version: UInt16
    public enum Operation: String, Codable, Sendable { case connect, reload, refresh, requestAccessibility, stop }
    public let requestID: UUID
    public let deadline: Date
    public let operation: Operation
    public let sessionID: UUID
    public let revision: UInt64
    public init(_ operation: Operation, sessionID: UUID, revision: UInt64) {
        version = Self.protocolVersion
        requestID = UUID(); deadline = Date().addingTimeInterval(10)
        self.operation = operation; self.sessionID = sessionID; self.revision = revision
    }
    public func validate() throws {
        guard version == Self.protocolVersion else { throw RuntimeAgentIPCError.protocolMismatch(expected: Self.protocolVersion, actual: version) }
        guard deadline > Date(), deadline.timeIntervalSinceNow <= 15 else { throw RuntimeAgentIPCError.requestExpired }
    }
}

/// Platform 只传送已编码的业务快照，不依赖 Finder/Window/Mouse 的模型。
public struct RuntimeHostReply: RuntimeAgentReplyProtocol {
    public let requestID: UUID
    public let errorMessage: String?
    public let sessionID: UUID?
    public let revision: UInt64?
    public let permissions: RuntimePermissionSnapshot?
    public let states: [String: Data]
    public init(requestID: UUID = UUID(), states: [String: Data] = [:], permissions: RuntimePermissionSnapshot? = nil, sessionID: UUID? = nil, revision: UInt64? = nil, errorMessage: String? = nil) {
        self.requestID = requestID; self.states = states; self.permissions = permissions; self.sessionID = sessionID; self.revision = revision; self.errorMessage = errorMessage
    }
}
