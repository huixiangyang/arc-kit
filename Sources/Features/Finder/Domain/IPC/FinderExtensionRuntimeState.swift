import ArcKitPlatform
import Darwin
import Foundation

public enum FinderExtensionRuntimeEvent: String, Codable, Equatable, Sendable {
    case initialized
    case observedDirectoriesUpdated
    case menuBuilt
    case actionSelected
    case actionDispatched
    case stateRequestResponse
}

public enum FinderExtensionActionDispatchStatus: String, Codable, Equatable, Sendable {
    case selected
    case extensionCompleted
    case commandQueued
    case cancelled
    case rejected
}

public struct FinderExtensionMenuBuildRuntime: Codable, Equatable, Sendable {
    public var menuKindRawValue: UInt
    public var itemCount: Int
    public var durationMs: Int
    public var builtAt: Date
    public var targetKind: FinderMenuTargetKind
    public var selectedItemCount: Int
    public var targetedPath: String?
    public var imageCount: Int

    public init(
        menuKindRawValue: UInt,
        itemCount: Int,
        durationMs: Int,
        builtAt: Date = Date(),
        targetKind: FinderMenuTargetKind,
        selectedItemCount: Int,
        targetedPath: String?,
        imageCount: Int
    ) {
        self.menuKindRawValue = menuKindRawValue
        self.itemCount = itemCount
        self.durationMs = durationMs
        self.builtAt = builtAt
        self.targetKind = targetKind
        self.selectedItemCount = selectedItemCount
        self.targetedPath = targetedPath
        self.imageCount = imageCount
    }
}

public struct FinderExtensionActionRuntime: Codable, Equatable, Sendable {
    public var actionID: String
    public var menuItemTag: Int
    public var title: String
    public var commandKind: FinderCommandKind
    public var selectedAt: Date
    public var targetKind: FinderMenuTargetKind
    public var selectedItemCount: Int
    public var targetPath: String?
    public var needsHostTargetResolution: Bool
    public var wasResolved: Bool
    public var executionMode: FinderActionExecutionMode
    public var dispatchStatus: FinderExtensionActionDispatchStatus
    public var requestID: UUID?
    public var failureReason: String?

    public init(
        actionID: String,
        menuItemTag: Int,
        title: String,
        commandKind: FinderCommandKind,
        selectedAt: Date = Date(),
        targetKind: FinderMenuTargetKind,
        selectedItemCount: Int,
        targetPath: String?,
        needsHostTargetResolution: Bool,
        wasResolved: Bool,
        executionMode: FinderActionExecutionMode,
        dispatchStatus: FinderExtensionActionDispatchStatus = .selected,
        requestID: UUID? = nil,
        failureReason: String? = nil
    ) {
        self.actionID = actionID
        self.menuItemTag = menuItemTag
        self.title = title
        self.commandKind = commandKind
        self.selectedAt = selectedAt
        self.targetKind = targetKind
        self.selectedItemCount = selectedItemCount
        self.targetPath = targetPath
        self.needsHostTargetResolution = needsHostTargetResolution
        self.wasResolved = wasResolved
        self.executionMode = executionMode
        self.dispatchStatus = dispatchStatus
        self.requestID = requestID
        self.failureReason = failureReason
    }
}

/// 每轮检测的关联回执；与菜单事件分开，后续菜单构建不能覆盖已经收到的回应。
public struct FinderExtensionStateResponse: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var respondedAt: Date

    public init(requestID: UUID, respondedAt: Date = Date()) {
        self.requestID = requestID
        self.respondedAt = respondedAt
    }
}

/// Finder 扩展通过经过代码身份校验的 Mach service 上报，Agent 负责写入诊断文件。
/// 扩展本身不触碰 `/tmp`，避免沙盒写入失败被误判为业务故障。
public struct FinderExtensionRuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var generatedAt: Date
    public var processID: Int32
    public var bundleIdentifier: String
    public var bundlePath: String
    public var executablePath: String
    public var event: FinderExtensionRuntimeEvent
    public var recentStateResponses: [FinderExtensionStateResponse]
    public var snapshotVersion: Int
    public var isMenuCachePrepared: Bool
    public var observedDirectoryPaths: [String]
    public var lastMenuBuild: FinderExtensionMenuBuildRuntime?
    public var lastAction: FinderExtensionActionRuntime?

    public init(
        schemaVersion: Int = FinderExtensionRuntimeState.currentSchemaVersion,
        generatedAt: Date = Date(),
        processID: Int32,
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        event: FinderExtensionRuntimeEvent,
        recentStateResponses: [FinderExtensionStateResponse] = [],
        snapshotVersion: Int,
        isMenuCachePrepared: Bool,
        observedDirectoryPaths: [String],
        lastMenuBuild: FinderExtensionMenuBuildRuntime? = nil,
        lastAction: FinderExtensionActionRuntime? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.event = event
        self.recentStateResponses = recentStateResponses
        self.snapshotVersion = snapshotVersion
        self.isMenuCachePrepared = isMenuCachePrepared
        self.observedDirectoryPaths = observedDirectoryPaths
        self.lastMenuBuild = lastMenuBuild
        self.lastAction = lastAction
    }

    public func hasRecentResponse(to requestID: UUID?, now: Date) -> Bool {
        recentStateResponses.contains { response in
            (requestID == nil || response.requestID == requestID)
                && (0...30).contains(now.timeIntervalSince(response.respondedAt))
        }
    }
}

public struct FinderExtensionRuntimeStateStore: Sendable {
    private struct FileEnvelope: Codable {
        static let currentSchemaVersion = 2

        var schemaVersion: Int
        var generatedAt: Date
        var states: [FinderExtensionRuntimeState]
    }

    public let stateURL: URL
    private let processIsRunning: @Sendable (Int32) -> Bool

    public init(
        stateURL: URL = URL(fileURLWithPath: ArcKitConstants.finderExtensionRuntimeStatePath),
        processIsRunning: (@Sendable (Int32) -> Bool)? = nil
    ) {
        self.stateURL = stateURL
        self.processIsRunning = processIsRunning ?? { processID in
            guard processID > 0 else { return false }
            return kill(pid_t(processID), 0) == 0 || errno == EPERM
        }
    }

    /// Finder Sync 会被 Finder 和系统 OpenPanel 分别托管，多个同路径进程是正常运行模型。
    /// Agent 作为唯一写入者按 PID 聚合运行态，并在每次上报时淘汰已经退出的宿主实例。
    public func record(_ state: FinderExtensionRuntimeState) throws {
        try validate(state)
        let existingStates = (try? loadAll()) ?? []
        var states = existingStates.filter { existing in
            existing.processID != state.processID && processIsRunning(existing.processID)
        }
        states.append(state)
        states.sort { $0.processID < $1.processID }
        try write(FileEnvelope(
            schemaVersion: FileEnvelope.currentSchemaVersion,
            generatedAt: Date(),
            states: states
        ))
    }

    public func loadAll() throws -> [FinderExtensionRuntimeState] {
        let data = try ArcKitBoundedFileReader.read(
            from: stateURL,
            maximumBytes: 1 * 1_024 * 1_024
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(FileEnvelope.self, from: data)
        guard envelope.schemaVersion == FileEnvelope.currentSchemaVersion else {
            throw ValidationError.schemaMismatch(
                expected: FileEnvelope.currentSchemaVersion,
                actual: envelope.schemaVersion
            )
        }
        guard !envelope.states.isEmpty,
              envelope.states.count <= 32,
              Set(envelope.states.map(\.processID)).count == envelope.states.count
        else {
            throw ValidationError.invalidProcessCollection
        }
        try envelope.states.forEach(validate)
        return envelope.states
    }

    public func loadLatest() throws -> FinderExtensionRuntimeState {
        guard let latest = try loadAll().max(by: { $0.generatedAt < $1.generatedAt }) else {
            throw ValidationError.invalidProcessCollection
        }
        return latest
    }

    /// 诊断与端到端验收优先读取最近真实动作，其次读取最近菜单构建，最后才读取心跳。
    public func loadMostRelevant() throws -> FinderExtensionRuntimeState {
        guard let state = try loadAll().max(by: { relevanceDate($0) < relevanceDate($1) }) else {
            throw ValidationError.invalidProcessCollection
        }
        return state
    }

    private func write(_ envelope: FileEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(envelope).write(to: stateURL, options: .atomic)
    }

    private func relevanceDate(_ state: FinderExtensionRuntimeState) -> Date {
        state.lastAction?.selectedAt ?? state.lastMenuBuild?.builtAt ?? state.generatedAt
    }

    private func validate(_ state: FinderExtensionRuntimeState) throws {
        guard state.schemaVersion == FinderExtensionRuntimeState.currentSchemaVersion else {
            throw ValidationError.schemaMismatch(
                expected: FinderExtensionRuntimeState.currentSchemaVersion,
                actual: state.schemaVersion
            )
        }
        guard state.recentStateResponses.count <= 8,
              Set(state.recentStateResponses.map(\.requestID)).count == state.recentStateResponses.count
        else { throw ValidationError.invalidProcessCollection }
        guard state.processID > 0,
              state.bundleIdentifier == ArcKitConstants.finderExtensionBundleIdentifier,
              state.bundlePath.hasSuffix("ArcKitFinderExtension.appex"),
              state.executablePath == "\(state.bundlePath)/Contents/MacOS/ArcKitFinderExtension"
        else {
            throw ValidationError.invalidExtensionIdentity
        }
        let sanitizedPaths = FinderObservedDirectoryBuilder.sanitizedObservedDirectoryPaths(
            state.observedDirectoryPaths,
            validationMode: .extensionRuntime
        )
        guard sanitizedPaths == state.observedDirectoryPaths else {
            throw ValidationError.invalidObservedDirectories
        }
        if let lastMenuBuild = state.lastMenuBuild {
            guard lastMenuBuild.itemCount >= 0,
                  lastMenuBuild.durationMs >= 0,
                  lastMenuBuild.selectedItemCount >= 0,
                  lastMenuBuild.imageCount >= 0,
                  lastMenuBuild.targetedPath.map({ $0.hasPrefix("/") }) ?? true,
                  Self.targetCountIsValid(
                      targetKind: lastMenuBuild.targetKind,
                      selectedItemCount: lastMenuBuild.selectedItemCount
                  )
            else {
                throw ValidationError.invalidMenuBuild
            }
        }
        if let lastAction = state.lastAction {
            guard !lastAction.actionID.isEmpty,
                  !lastAction.title.isEmpty,
                  lastAction.selectedItemCount >= 0,
                  lastAction.targetPath.map({ $0.hasPrefix("/") }) ?? true,
                  Self.targetCountIsValid(
                      targetKind: lastAction.targetKind,
                      selectedItemCount: lastAction.selectedItemCount
                  ),
                  !lastAction.needsHostTargetResolution || (
                      lastAction.targetKind == .blank
                          && lastAction.selectedItemCount == 0
                          && lastAction.targetPath == nil
                  )
            else {
                throw ValidationError.invalidAction
            }
            switch lastAction.dispatchStatus {
            case .selected:
                guard lastAction.requestID == nil,
                      lastAction.failureReason == nil
                else {
                    throw ValidationError.invalidAction
                }
            case .extensionCompleted:
                guard lastAction.executionMode == .extensionLocal,
                      lastAction.requestID == nil,
                      lastAction.failureReason == nil
                else {
                    throw ValidationError.invalidAction
                }
            case .commandQueued:
                guard lastAction.executionMode == .agent,
                      lastAction.requestID != nil,
                      lastAction.failureReason == nil
                else {
                    throw ValidationError.invalidAction
                }
            case .cancelled:
                guard lastAction.requestID == nil,
                      lastAction.failureReason?.isEmpty == false
                else {
                    throw ValidationError.invalidAction
                }
            case .rejected:
                guard lastAction.requestID == nil,
                      lastAction.failureReason?.isEmpty == false
                else {
                    throw ValidationError.invalidAction
                }
            }
        }
    }

    private static func targetCountIsValid(
        targetKind: FinderMenuTargetKind,
        selectedItemCount: Int
    ) -> Bool {
        switch targetKind {
        case .blank:
            selectedItemCount == 0
        case .files, .folders, .images, .mixed:
            selectedItemCount > 0
        }
    }

    public enum ValidationError: Error, LocalizedError {
        case schemaMismatch(expected: Int, actual: Int)
        case invalidExtensionIdentity
        case invalidObservedDirectories
        case invalidMenuBuild
        case invalidAction
        case invalidProcessCollection

        public var errorDescription: String? {
            switch self {
            case let .schemaMismatch(expected, actual):
                L10n.string(.Finder.extensionStateSchemaMismatch(String(describing: expected), String(describing: actual)))
            case .invalidExtensionIdentity:
                L10n.string(.Finder.extensionStateInvalidIdentity)
            case .invalidObservedDirectories:
                L10n.string(.Finder.extensionStateUnsafeDirectories)
            case .invalidMenuBuild:
                L10n.string(.Finder.extensionStateInvalidFinderExtensionMenuRuntime)
            case .invalidAction:
                L10n.string(.Finder.extensionStateInvalidFinderExtensionActionRuntime)
            case .invalidProcessCollection:
                L10n.string(.Finder.extensionStateInvalidProcesses)
            }
        }
    }
}
