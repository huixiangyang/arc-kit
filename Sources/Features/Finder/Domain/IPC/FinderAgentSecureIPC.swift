import ArcKitPlatform
import Foundation

/// Finder 扩展与 Finder Agent 之间唯一允许的副作用通信协议。
///
/// 命令、快照和运行态全部走 launchd Mach service。分布式通知只保留为无载荷的
/// “配置已变化”信号，任何进程都不能再通过伪造通知让 Agent 执行文件操作。
public enum FinderAgentSecureIPCOperation: String, CaseIterable, Sendable {
    case submitCommand
    case fetchSnapshot
    case reportRuntimeState
}

public struct FinderAgentSecureIPCReply: Codable, Equatable, Sendable {
    public var commandAcceptance: FinderCommandAcceptance?
    public var snapshot: FinderExtensionSnapshot?
    public var runtimeStateRecorded: Bool?
    public var errorMessage: String?

    public init(
        commandAcceptance: FinderCommandAcceptance? = nil,
        snapshot: FinderExtensionSnapshot? = nil,
        runtimeStateRecorded: Bool? = nil,
        errorMessage: String? = nil
    ) {
        self.commandAcceptance = commandAcceptance
        self.snapshot = snapshot
        self.runtimeStateRecorded = runtimeStateRecorded
        self.errorMessage = errorMessage
    }
}

public enum FinderAgentSecureIPCError: LocalizedError, Equatable, Sendable {
    case malformedMessage
    case missingPayload
    case unexpectedPayload
    case malformedReply
    case payloadTooLarge
    case remoteFailure(String)
    case connectionFailed(String)
    case peerIdentityUnavailable(String)
    case peerIdentityMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .malformedMessage:
            L10n.string(.Finder.ipcUnrecognizedFinderSecureIpcMessage)
        case .missingPayload:
            L10n.string(.Finder.ipcRequiredFinderSecureIpcPayloadMissing)
        case .unexpectedPayload:
            L10n.string(.Finder.ipcFinderSecureIpcContainsPayloadDisallowed)
        case .malformedReply:
            L10n.string(.Finder.ipcFinderAgentReturnedDamagedResponse)
        case .payloadTooLarge:
            L10n.string(.Finder.ipcPayloadLimit)
        case let .remoteFailure(message):
            message
        case let .connectionFailed(message):
            L10n.string(.Finder.ipcConnectionFailed(String(describing: message)))
        case let .peerIdentityUnavailable(message):
            L10n.string(.Finder.ipcIdentityFailed(String(describing: message)))
        case let .peerIdentityMismatch(message):
            L10n.string(.Finder.ipcFinderComponentIdentityMismatch(String(describing: message)))
        }
    }
}

public extension FinderAgentSecureIPCReply {
    func validate(for operation: FinderAgentSecureIPCOperation) throws {
        guard errorMessage == nil else { throw FinderAgentSecureIPCError.malformedReply }
        switch operation {
        case .submitCommand:
            guard commandAcceptance != nil, snapshot == nil, runtimeStateRecorded == nil else {
                throw FinderAgentSecureIPCError.malformedReply
            }
        case .fetchSnapshot:
            guard commandAcceptance == nil, snapshot != nil, runtimeStateRecorded == nil else {
                throw FinderAgentSecureIPCError.malformedReply
            }
        case .reportRuntimeState:
            guard commandAcceptance == nil, snapshot == nil, runtimeStateRecorded != nil else {
                throw FinderAgentSecureIPCError.malformedReply
            }
        }
    }
}

public enum FinderAgentSecureIPCCodec {
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let operationKey = "operation"
    public static let payloadKey = "payload"
    public static let replyKey = "reply"

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        try validateSize(of: data)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try validateSize(of: data)
        return try JSONDecoder().decode(type, from: data)
    }

    public static func encodeReply(_ reply: FinderAgentSecureIPCReply) throws -> Data {
        try encode(reply)
    }

    public static func decodeReply(_ data: Data) throws -> FinderAgentSecureIPCReply {
        let reply = try decode(FinderAgentSecureIPCReply.self, from: data)
        if let errorMessage = reply.errorMessage {
            guard reply.commandAcceptance == nil,
                  reply.snapshot == nil,
                  reply.runtimeStateRecorded == nil
            else {
                throw FinderAgentSecureIPCError.malformedReply
            }
            throw FinderAgentSecureIPCError.remoteFailure(errorMessage)
        }
        return reply
    }

    private static func validateSize(of data: Data) throws {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            if data.count > maximumPayloadBytes {
                throw FinderAgentSecureIPCError.payloadTooLarge
            }
            throw FinderAgentSecureIPCError.malformedMessage
        }
    }
}
