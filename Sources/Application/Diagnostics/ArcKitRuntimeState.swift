import ArcKitFinder
import ArcKitPlatform
import ArcKitMouse
import ArcKitWindow
import Foundation

public enum ArcKitServiceRuntimeState: String, Codable, Equatable, Sendable {
    case stopped
    case unavailable
    case waitingForAccessibility
    case running
    case failed
    case failedToCreateEventTap
    case disabledByUserInput
    case eventTapInvalidated
}

public struct ArcKitMouseRuntimeState: Codable, Equatable, Sendable {
    public var agentProcessID: Int32
    public var agentLaunchID: UUID
    public var isEnabled: Bool
    public var accessibilityTrusted: Bool?
    public var state: ArcKitServiceRuntimeState
    public var lastRuntimeWarning: String?
    public var lastFailureReason: String?
    public var scrollDiagnostics: MouseScrollDiagnostics

    public init(
        agentProcessID: Int32,
        agentLaunchID: UUID,
        isEnabled: Bool,
        accessibilityTrusted: Bool?,
        state: ArcKitServiceRuntimeState,
        lastRuntimeWarning: String? = nil,
        lastFailureReason: String? = nil,
        scrollDiagnostics: MouseScrollDiagnostics = MouseScrollDiagnostics()
    ) {
        self.agentProcessID = agentProcessID
        self.agentLaunchID = agentLaunchID
        self.isEnabled = isEnabled
        self.accessibilityTrusted = accessibilityTrusted
        self.state = state
        self.lastRuntimeWarning = lastRuntimeWarning
        self.lastFailureReason = lastFailureReason
        self.scrollDiagnostics = scrollDiagnostics
    }
}

public struct ArcKitWindowRuntimeState: Codable, Equatable, Sendable {
    public var agentProcessID: Int32
    public var agentLaunchID: UUID
    public var isEnabled: Bool
    public var hotKeysEnabled: Bool
    public var dragSnapEnabled: Bool
    public var accessibilityTrusted: Bool?
    public var accessibilityOperational: Bool
    public var state: ArcKitServiceRuntimeState
    public var hotKeyRegisteredCount: Int
    public var hotKeyFailedCount: Int
    public var hotKeyUnsafeCount: Int
    public var hotKeyDuplicateCount: Int
    public var hotKeyHandlerInstallationFailed: Bool
    public var hotKeyRuntimeWarning: String?
    public var dragSnapState: ArcKitServiceRuntimeState
    public var dragSnapFailureMessage: String?
    public var lastActionSucceeded: Bool?
    public var lastActionMessage: String?

    public init(
        agentProcessID: Int32,
        agentLaunchID: UUID,
        isEnabled: Bool,
        hotKeysEnabled: Bool,
        dragSnapEnabled: Bool,
        accessibilityTrusted: Bool?,
        accessibilityOperational: Bool = true,
        state: ArcKitServiceRuntimeState,
        hotKeyRegisteredCount: Int,
        hotKeyFailedCount: Int,
        hotKeyUnsafeCount: Int,
        hotKeyDuplicateCount: Int,
        hotKeyHandlerInstallationFailed: Bool,
        hotKeyRuntimeWarning: String? = nil,
        dragSnapState: ArcKitServiceRuntimeState,
        dragSnapFailureMessage: String? = nil,
        lastActionSucceeded: Bool? = nil,
        lastActionMessage: String? = nil
    ) {
        self.agentProcessID = agentProcessID
        self.agentLaunchID = agentLaunchID
        self.isEnabled = isEnabled
        self.hotKeysEnabled = hotKeysEnabled
        self.dragSnapEnabled = dragSnapEnabled
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityOperational = accessibilityOperational
        self.state = state
        self.hotKeyRegisteredCount = hotKeyRegisteredCount
        self.hotKeyFailedCount = hotKeyFailedCount
        self.hotKeyUnsafeCount = hotKeyUnsafeCount
        self.hotKeyDuplicateCount = hotKeyDuplicateCount
        self.hotKeyHandlerInstallationFailed = hotKeyHandlerInstallationFailed
        self.hotKeyRuntimeWarning = hotKeyRuntimeWarning
        self.dragSnapState = dragSnapState
        self.dragSnapFailureMessage = dragSnapFailureMessage
        self.lastActionSucceeded = lastActionSucceeded
        self.lastActionMessage = lastActionMessage
    }
}

public struct ArcKitMainAppRuntimeState: Codable, Equatable, Sendable {
    public static let schemaVersion = 7

    public var schemaVersion: Int
    public var generatedAt: Date
    public var processID: Int32
    public var executablePath: String
    public var bundlePath: String
    public var launchArguments: [String]
    public var finderExtensionEnabledByUser: Bool
    public var mouseEnhancement: ArcKitMouseRuntimeState
    public var windowManagement: ArcKitWindowRuntimeState

    public init(
        schemaVersion: Int = ArcKitMainAppRuntimeState.schemaVersion,
        generatedAt: Date,
        processID: Int32,
        executablePath: String,
        bundlePath: String,
        launchArguments: [String],
        finderExtensionEnabledByUser: Bool,
        mouseEnhancement: ArcKitMouseRuntimeState,
        windowManagement: ArcKitWindowRuntimeState
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.processID = processID
        self.executablePath = executablePath
        self.bundlePath = bundlePath
        self.launchArguments = launchArguments
        self.finderExtensionEnabledByUser = finderExtensionEnabledByUser
        self.mouseEnhancement = mouseEnhancement
        self.windowManagement = windowManagement
    }

    /// generatedAt 只表示文件新鲜度；除它之外的运行事实相同时无需重复原子写盘。
    public func hasSameRuntimeFacts(as other: Self) -> Bool {
        var current = self
        var candidate = other
        current.generatedAt = .distantPast
        candidate.generatedAt = .distantPast
        return current == candidate
    }
}

public enum ArcKitRuntimeStateStore {
    public static var stateURL: URL {
        URL(fileURLWithPath: ArcKitConstants.mainAppRuntimeStatePath)
    }

    public static func save(_ state: ArcKitMainAppRuntimeState, to url: URL = stateURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = stateURL) throws -> ArcKitMainAppRuntimeState {
        let data = try ArcKitBoundedFileReader.read(from: url, maximumBytes: 1 * 1_024 * 1_024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(ArcKitMainAppRuntimeState.self, from: data)
        guard state.schemaVersion == ArcKitMainAppRuntimeState.schemaVersion else {
            throw RuntimeStateError.schemaMismatch(expected: ArcKitMainAppRuntimeState.schemaVersion, actual: state.schemaVersion)
        }
        return state
    }

    public enum RuntimeStateError: Error, LocalizedError {
        case schemaMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case let .schemaMismatch(expected, actual):
                L10n.string(.Diagnostics.runtimeRuntimeSchemaMismatchExpectedActual(String(describing: expected), String(describing: actual)))
            }
        }
    }
}
