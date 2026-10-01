import ArcKitFinder
import ArcKitPlatform
import Foundation

/// Finder 高风险动作的一次性子进程协议。Worker 每次只处理一个请求，结束后立即退出。
public struct FinderOperationWorkerRequest: Codable, Equatable, Sendable {
    public static let protocolVersion: UInt16 = 2

    public var version: UInt16
    public var requestID: UUID
    public var deadline: Date
    public var command: FinderCommandRequest
    public var language: ArcKitLanguage
    public var settings: FinderRuntimeSettings

    public init(
        command: FinderCommandRequest,
        settings: FinderRuntimeSettings,
        language: ArcKitLanguage = L10n.language,
        timeout: TimeInterval = 120
    ) {
        version = Self.protocolVersion
        requestID = command.id
        deadline = Date().addingTimeInterval(max(1, timeout))
        self.command = command
        self.language = language
        self.settings = settings
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.protocolVersion else {
            throw FinderOperationWorkerError.protocolMismatch(
                expected: Self.protocolVersion,
                actual: version
            )
        }
        guard requestID == command.id else {
            throw FinderOperationWorkerError.requestIdentityMismatch
        }
        guard deadline > now else { throw FinderOperationWorkerError.requestExpired }
        guard command.kind != .extensionLocalInfo else {
            throw FinderOperationWorkerError.operationNotAllowed
        }
    }
}

public struct FinderOperationWorkerReply: Codable, Equatable, Sendable {
    public var version: UInt16
    public var requestID: UUID
    public var result: FinderCommandExecutionResult?
    public var errorMessage: String?

    public init(
        requestID: UUID,
        result: FinderCommandExecutionResult? = nil,
        errorMessage: String? = nil
    ) {
        version = FinderOperationWorkerRequest.protocolVersion
        self.requestID = requestID
        self.result = result
        self.errorMessage = errorMessage
    }

    public func validate(expectedRequestID: UUID) throws {
        guard version == FinderOperationWorkerRequest.protocolVersion else {
            throw FinderOperationWorkerError.protocolMismatch(
                expected: FinderOperationWorkerRequest.protocolVersion,
                actual: version
            )
        }
        guard requestID == expectedRequestID else {
            throw FinderOperationWorkerError.requestIdentityMismatch
        }
        if let errorMessage {
            throw FinderOperationWorkerError.remoteFailure(errorMessage)
        }
    }
}

public enum FinderOperationWorkerError: LocalizedError, Equatable, Sendable {
    case busy
    case outputDidNotClose
    case protocolMismatch(expected: UInt16, actual: UInt16)
    case requestIdentityMismatch
    case requestExpired
    case operationNotAllowed
    case executableUnavailable
    case launchFailed(String)
    case timedOut
    case crashed(status: Int32, detail: String)
    case malformedReply
    case requestTooLarge
    case responseTooLarge
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            L10n.string(.FinderActions.workerProtocolAnotherFinderOperationRunningWait)
        case .outputDidNotClose:
            L10n.string(.FinderActions.workerProtocolPipeNotClosed)
        case let .protocolMismatch(expected, actual):
            L10n.string(.FinderActions.workerProtocolVersionMismatch(String(describing: expected), String(describing: actual)))
        case .requestIdentityMismatch:
            L10n.string(.FinderActions.workerProtocolResponseMismatch)
        case .requestExpired:
            L10n.string(.FinderActions.workerProtocolFinderWorkerRequestExpired)
        case .operationNotAllowed:
            L10n.string(.FinderActions.workerProtocolOperationRejected)
        case .executableUnavailable:
            L10n.string(.FinderActions.workerProtocolFinderWorkerExecutableMissing)
        case let .launchFailed(message):
            L10n.string(.FinderActions.workerProtocolFinderWorkerStartFailed(String(describing: message)))
        case .timedOut:
            L10n.string(.FinderActions.workerProtocolFinderActionTimeoutIsolatedWorker)
        case let .crashed(status, detail):
            L10n.string(.FinderActions.workerProtocolFinderWorkerExitedUnexpectedly(String(describing: status), String(describing: detail)))
        case .malformedReply:
            L10n.string(.FinderActions.workerProtocolFinderWorkerReturnedDamagedResponse)
        case .requestTooLarge:
            L10n.string(.FinderActions.workerProtocolFinderWorkerRequestExceedsSizeLimit)
        case .responseTooLarge:
            L10n.string(.FinderActions.workerProtocolResponseTooLarge)
        case let .remoteFailure(message):
            message
        }
    }
}

public enum FinderOperationWorkerCodec {
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else {
            throw data.isEmpty
                ? FinderOperationWorkerError.malformedReply
                : FinderOperationWorkerError.responseTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
