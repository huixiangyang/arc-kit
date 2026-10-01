import ArcKitPlatform
import Foundation

public enum MouseAgentOperation: String, Codable, CaseIterable, Sendable {
    case fetchState
}

public struct MouseAgentRuntimeSnapshot: Codable, Equatable, Sendable {
    public var lifecycle: RuntimeAgentLifecycleState
    public var processID: Int32
    public var launchID: UUID
    public var accessibilityTrusted: Bool
    public var lastRuntimeWarning: String?
    public var lastFailureReason: String?
    public var scrollDiagnostics: MouseScrollDiagnostics
    public var updatedAt: Date

    public init(
        lifecycle: RuntimeAgentLifecycleState,
        processID: Int32,
        launchID: UUID,
        accessibilityTrusted: Bool,
        lastRuntimeWarning: String? = nil,
        lastFailureReason: String? = nil,
        scrollDiagnostics: MouseScrollDiagnostics = MouseScrollDiagnostics(),
        updatedAt: Date = Date()
    ) {
        self.lifecycle = lifecycle
        self.processID = processID
        self.launchID = launchID
        self.accessibilityTrusted = accessibilityTrusted
        self.lastRuntimeWarning = lastRuntimeWarning
        self.lastFailureReason = lastFailureReason
        self.scrollDiagnostics = scrollDiagnostics
        self.updatedAt = updatedAt
    }

    public func hasSameRuntimeFacts(as other: Self) -> Bool {
        var current = self
        var candidate = other
        current.updatedAt = .distantPast
        candidate.updatedAt = .distantPast
        return current == candidate
    }
}

public struct MouseAgentRequest: RuntimeAgentRequestProtocol, Equatable {
    public static let protocolVersion: UInt16 = 5

    public var version: UInt16
    public var requestID: UUID
    public var sessionID: UUID?
    public var revision: UInt64?
    public var operation: MouseAgentOperation
    public var deadline: Date

    public init(
        operation: MouseAgentOperation,
        timeout: TimeInterval = 2
    ) {
        version = Self.protocolVersion
        requestID = UUID()
        self.operation = operation
        deadline = Date().addingTimeInterval(max(0.1, timeout))
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.protocolVersion else {
            throw RuntimeAgentIPCError.protocolMismatch(expected: Self.protocolVersion, actual: version)
        }
        guard deadline > now else { throw RuntimeAgentIPCError.requestExpired }
    }
}

public struct MouseAgentReply: RuntimeAgentReplyProtocol, Equatable {
    public var requestID: UUID
    public var state: MouseAgentRuntimeSnapshot?
    public var errorMessage: String?

    public init(
        requestID: UUID,
        state: MouseAgentRuntimeSnapshot? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.state = state
        self.errorMessage = errorMessage
    }

    public func validate() throws {
        if errorMessage != nil {
            guard state == nil else { throw RuntimeAgentIPCError.malformedReply }
            return
        }
        guard state != nil else { throw RuntimeAgentIPCError.malformedReply }
    }
}
