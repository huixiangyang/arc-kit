import ArcKitPlatform
import CoreGraphics
import Foundation

public enum WindowSceneItemStatus: String, Codable, Equatable, Sendable {
    case applied, unchanged, constrained, missingWindow, ambiguousWindow, missingDisplay
    case conflictingAssignment, excludedApplication, unavailable, failed

    public var isSuccess: Bool { self == .applied || self == .unchanged }
    public var displayName: String {
        switch self {
        case .applied: L10n.string(.Window.sceneResultApplied)
        case .unchanged: L10n.string(.Window.sceneResultUnchanged)
        case .constrained: L10n.string(.Window.sceneResultConstrained)
        case .missingWindow: L10n.string(.Window.sceneResultMissingWindow)
        case .ambiguousWindow: L10n.string(.Window.sceneResultAmbiguousWindow)
        case .missingDisplay: L10n.string(.Window.sceneResultMissingDisplay)
        case .conflictingAssignment: L10n.string(.Window.sceneResultConflictingAssignment)
        case .excludedApplication: L10n.string(.Window.sceneResultExcludedApplication)
        case .unavailable: L10n.string(.Window.sceneResultUnavailable)
        case .failed: L10n.string(.Window.sceneResultFailed)
        }
    }
}

public struct WindowSceneItemResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { entryID }
    public var entryID: UUID
    public var status: WindowSceneItemStatus
    public var message: String?
    public var actualFrame: CGRect?
    public var candidateIDs: [UUID]

    public init(entryID: UUID, status: WindowSceneItemStatus, message: String? = nil,
                actualFrame: CGRect? = nil, candidateIDs: [UUID] = []) {
        self.entryID = entryID
        self.status = status
        self.message = message
        self.actualFrame = actualFrame
        self.candidateIDs = candidateIDs
    }
}

public enum WindowSceneExecutionOperation: String, Codable, Sendable { case apply, undo }

public struct WindowSceneExecutionReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sceneID: UUID
    public var sceneName: String
    public var operation: WindowSceneExecutionOperation
    public var items: [WindowSceneItemResult]
    /// 仅由执行 Host 签发；重启后失效，绝不持久化窗口撤销栈。
    public var undoToken: UUID?
    public var focusFailureMessage: String?
    public var completedAt: Date

    public init(id: UUID = UUID(), sceneID: UUID, sceneName: String, operation: WindowSceneExecutionOperation = .apply,
                items: [WindowSceneItemResult], undoToken: UUID? = nil, focusFailureMessage: String? = nil, completedAt: Date = Date()) {
        self.id = id
        self.sceneID = sceneID
        self.sceneName = sceneName
        self.operation = operation
        self.items = items
        self.undoToken = undoToken
        self.focusFailureMessage = focusFailureMessage
        self.completedAt = completedAt
    }

    public var successfulCount: Int { items.filter { $0.status.isSuccess }.count }
    public var needsAttention: Bool { items.contains { !$0.status.isSuccess } || focusFailureMessage != nil }
}
