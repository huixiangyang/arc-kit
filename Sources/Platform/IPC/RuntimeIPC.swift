import Foundation

public enum RuntimeAgentLifecycleState: String, Codable, Equatable, Sendable {
    case starting
    case stopped
    case waitingForAccessibility
    case running
    case degraded
    case safeMode
    case unavailable
}

public enum RuntimeAgentIPCError: Error, LocalizedError, Equatable, Sendable {
    case protocolMismatch(expected: UInt16, actual: UInt16)
    case requestExpired
    case missingPayload
    case unexpectedPayload
    case payloadTooLarge
    case operationNotAllowed
    case malformedMessage
    case malformedReply
    case connectionFailed(String)
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .protocolMismatch(expected, actual):
            L10n.string(.Platform.ipcAgentProtocolMismatchExpectedActual(String(describing: expected), String(describing: actual)))
        case .requestExpired: L10n.string(.Platform.ipcAgentRequestExpired)
        case .missingPayload: L10n.string(.Platform.ipcAgentRequestLacksRequiredData)
        case .unexpectedPayload: L10n.string(.Platform.ipcAgentRequestIncludesDataDisallowed)
        case .payloadTooLarge: L10n.string(.Platform.ipcAgentRequestResponseExceedsSize)
        case .operationNotAllowed: L10n.string(.Platform.ipcAgentRejectedOperationOutsideResponsibility)
        case .malformedMessage: L10n.string(.Platform.ipcAgentReceivedDamagedRequest)
        case .malformedReply: L10n.string(.Platform.ipcAgentReturnedDamagedResponse)
        case let .connectionFailed(message): L10n.string(.Platform.ipcAgentConnectionFailed(String(describing: message)))
        case let .remoteFailure(message): message
        }
    }
}

public enum RuntimeAgentIPCCodec {
    public static let payloadKey = "payload"
    public static let replyKey = "reply"
    public static let maximumPayloadBytes = 1 * 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw data.isEmpty ? RuntimeAgentIPCError.malformedMessage : RuntimeAgentIPCError.payloadTooLarge
        }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw data.isEmpty ? RuntimeAgentIPCError.malformedMessage : RuntimeAgentIPCError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public protocol RuntimeAgentRequestProtocol: Codable, Sendable {
    var requestID: UUID { get }
    var deadline: Date { get }
}

public protocol RuntimeAgentReplyProtocol: Codable, Sendable {
    var requestID: UUID { get }
    var errorMessage: String? { get }
}
