import ArcKitPlatform
import Foundation

public enum WindowAgentOperation: String, Codable, CaseIterable, Sendable {
    case performAction
    case captureTarget
    case fetchState
    case sceneInventory
    case applyScene
    case undoScene
}

public enum WindowAgentDragSnapState: String, Codable, Equatable, Sendable {
    case stopped
    case waitingForAccessibility
    case running
    case failed
}

public struct WindowAgentRuntimeSnapshot: Codable, Equatable, Sendable {
    public var lifecycle: RuntimeAgentLifecycleState
    public var processID: Int32
    public var launchID: UUID
    public var accessibilityTrusted: Bool
    public var accessibilityOperational: Bool
    public var hotKeyRegisteredCount: Int
    public var hotKeyFailedBindings: [WindowHotKeyBinding]
    public var hotKeyDuplicateBindings: [WindowHotKeyBinding]
    public var hotKeyUnsafeBindings: [WindowHotKeyBinding]
    public var hotKeyHandlerInstallationFailed: Bool
    public var hotKeyRuntimeWarning: String?
    public var dragSnapState: WindowAgentDragSnapState
    public var dragSnapFailureMessage: String?
    public var lastResult: WindowManagementResult?
    public var configurableApplicationCandidate: AppConfigurationCandidate?
    public var lastSceneResult: WindowSceneExecutionReport?
    public var sceneHotKeyFailures: [UUID: String]
    public var updatedAt: Date

    public init(
        lifecycle: RuntimeAgentLifecycleState,
        processID: Int32,
        launchID: UUID,
        accessibilityTrusted: Bool,
        accessibilityOperational: Bool,
        hotKeyRegisteredCount: Int = 0,
        hotKeyFailedBindings: [WindowHotKeyBinding] = [],
        hotKeyDuplicateBindings: [WindowHotKeyBinding] = [],
        hotKeyUnsafeBindings: [WindowHotKeyBinding] = [],
        hotKeyHandlerInstallationFailed: Bool = false,
        hotKeyRuntimeWarning: String? = nil,
        dragSnapState: WindowAgentDragSnapState = .stopped,
        dragSnapFailureMessage: String? = nil,
        lastResult: WindowManagementResult? = nil,
        configurableApplicationCandidate: AppConfigurationCandidate? = nil,
        lastSceneResult: WindowSceneExecutionReport? = nil,
        sceneHotKeyFailures: [UUID: String] = [:],
        updatedAt: Date = Date()
    ) {
        self.lifecycle = lifecycle
        self.processID = processID
        self.launchID = launchID
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityOperational = accessibilityOperational
        self.hotKeyRegisteredCount = hotKeyRegisteredCount
        self.hotKeyFailedBindings = hotKeyFailedBindings
        self.hotKeyDuplicateBindings = hotKeyDuplicateBindings
        self.hotKeyUnsafeBindings = hotKeyUnsafeBindings
        self.hotKeyHandlerInstallationFailed = hotKeyHandlerInstallationFailed
        self.hotKeyRuntimeWarning = hotKeyRuntimeWarning
        self.dragSnapState = dragSnapState
        self.dragSnapFailureMessage = dragSnapFailureMessage
        self.lastResult = lastResult
        self.configurableApplicationCandidate = configurableApplicationCandidate
        self.lastSceneResult = lastSceneResult
        self.sceneHotKeyFailures = sceneHotKeyFailures
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

public struct WindowAgentRequest: RuntimeAgentRequestProtocol, Equatable {
    public static let protocolVersion: UInt16 = 7

    public var version: UInt16
    public var requestID: UUID
    public var sessionID: UUID?
    public var revision: UInt64?
    public var operation: WindowAgentOperation
    public var deadline: Date
    public var action: WindowLayoutAction?
    public var targetID: UUID?
    public var captureApplication: AppConfigurationCandidate?
    public var sceneID: UUID?
    public var undoToken: UUID?

    public init(
        operation: WindowAgentOperation,
        timeout: TimeInterval? = nil,
        action: WindowLayoutAction? = nil,
        targetID: UUID? = nil,
        captureApplication: AppConfigurationCandidate? = nil,
        sceneID: UUID? = nil,
        undoToken: UUID? = nil
    ) {
        version = Self.protocolVersion
        requestID = UUID()
        self.operation = operation
        let defaultTimeout: TimeInterval = switch operation {
        case .sceneInventory: 13
        case .applyScene, .undoScene: 35
        case .performAction, .captureTarget, .fetchState: 2
        }
        deadline = Date().addingTimeInterval(max(0.1, timeout ?? defaultTimeout))
        self.action = action
        self.targetID = targetID
        self.captureApplication = captureApplication
        self.sceneID = sceneID
        self.undoToken = undoToken
    }

    /// 场景的传输等待包含五秒收尾余量，Host 在此之前停止签发新的窗口动作。
    public var sceneExecutionDeadline: Date { deadline.addingTimeInterval(-5) }

    public func validate(now: Date = Date()) throws {
        guard version == Self.protocolVersion else {
            throw RuntimeAgentIPCError.protocolMismatch(expected: Self.protocolVersion, actual: version)
        }
        guard deadline > now else { throw RuntimeAgentIPCError.requestExpired }
        if operation != .applyScene, sceneID != nil { throw RuntimeAgentIPCError.unexpectedPayload }
        if operation != .undoScene, undoToken != nil { throw RuntimeAgentIPCError.unexpectedPayload }
        switch operation {
        case .performAction:
            guard action != nil else { throw RuntimeAgentIPCError.missingPayload }
            guard captureApplication == nil else { throw RuntimeAgentIPCError.unexpectedPayload }
        case .captureTarget:
            guard action == nil, targetID == nil else { throw RuntimeAgentIPCError.unexpectedPayload }
            if let captureApplication {
                guard captureApplication.processIdentifier > 0, !captureApplication.bundleIdentifier.isEmpty else {
                    throw RuntimeAgentIPCError.missingPayload
                }
            }
        case .applyScene, .undoScene:
            guard deadline.timeIntervalSince(now) <= 35 else { throw RuntimeAgentIPCError.requestExpired }
            guard action == nil, targetID == nil, captureApplication == nil else { throw RuntimeAgentIPCError.unexpectedPayload }
            guard operation == .applyScene ? sceneID != nil : undoToken != nil else { throw RuntimeAgentIPCError.missingPayload }
        case .sceneInventory:
            guard deadline.timeIntervalSince(now) <= 13 else { throw RuntimeAgentIPCError.requestExpired }
            guard action == nil, targetID == nil, captureApplication == nil else { throw RuntimeAgentIPCError.unexpectedPayload }
        case .fetchState:
            guard action == nil, targetID == nil, captureApplication == nil else { throw RuntimeAgentIPCError.unexpectedPayload }
        }
    }
}

/// 只有实际捕获到窗口才签发令牌；不可用是业务结果，不代表后台连接失败。
public enum WindowTargetCaptureResult: Codable, Equatable, Sendable {
    case ready(UUID)
    case unavailable(String)

    public var targetID: UUID? {
        guard case let .ready(id) = self else { return nil }
        return id
    }

    public var failureMessage: String? {
        guard case let .unavailable(message) = self else { return nil }
        return message
    }
}

public struct WindowAgentReply: RuntimeAgentReplyProtocol, Equatable {
    public var requestID: UUID
    public var state: WindowAgentRuntimeSnapshot?
    public var result: WindowManagementResult?
    public var errorMessage: String?
    public var targetCapture: WindowTargetCaptureResult?
    public var sceneInventory: WindowSceneInventory?
    public var sceneResult: WindowSceneExecutionReport?

    public init(
        requestID: UUID,
        state: WindowAgentRuntimeSnapshot? = nil,
        result: WindowManagementResult? = nil,
        errorMessage: String? = nil,
        targetCapture: WindowTargetCaptureResult? = nil,
        sceneInventory: WindowSceneInventory? = nil,
        sceneResult: WindowSceneExecutionReport? = nil
    ) {
        self.requestID = requestID
        self.state = state
        self.result = result
        self.errorMessage = errorMessage
        self.targetCapture = targetCapture
        self.sceneInventory = sceneInventory
        self.sceneResult = sceneResult
    }

    public func validate(operation: WindowAgentOperation) throws {
        if errorMessage != nil {
            guard state == nil, result == nil, targetCapture == nil, sceneInventory == nil, sceneResult == nil else { throw RuntimeAgentIPCError.malformedReply }
            return
        }
        guard state != nil else { throw RuntimeAgentIPCError.malformedReply }
        guard (operation == .captureTarget) == (targetCapture != nil) else {
            throw RuntimeAgentIPCError.malformedReply
        }
        guard (operation == .sceneInventory) == (sceneInventory != nil),
              (operation == .applyScene || operation == .undoScene) == (sceneResult != nil) else {
            throw RuntimeAgentIPCError.malformedReply
        }
        if let sceneResult {
            guard (operation == .undoScene) == (sceneResult.operation == .undo),
                  Set(sceneResult.items.map(\.entryID)).count == sceneResult.items.count else {
                throw RuntimeAgentIPCError.malformedReply
            }
        }
        if operation == .performAction {
            guard result != nil else { throw RuntimeAgentIPCError.malformedReply }
        } else if result != nil {
            throw RuntimeAgentIPCError.malformedReply
        }
    }
}
