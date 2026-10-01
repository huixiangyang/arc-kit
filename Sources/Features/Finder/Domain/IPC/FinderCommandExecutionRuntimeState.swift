import ArcKitPlatform
import Foundation

public enum FinderCommandExecutionRuntimeStatus: String, Codable, Equatable, Sendable {
    case started
    case cancelled
    case succeeded
    case failed
}

/// Finder Agent 最近一次命令的结构化执行真值。
///
/// 该文件只用于本机诊断和安装态验收，不参与命令投递；正式命令链路只走安全 Mach Service。
public struct FinderCommandExecutionRuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var generatedAt: Date
    public var requestID: UUID
    public var kind: FinderCommandKind
    public var status: FinderCommandExecutionRuntimeStatus
    public var startedAt: Date
    public var completedAt: Date?
    public var agentProcessID: Int32
    public var agentBundleIdentifier: String
    public var agentBundlePath: String
    public var agentExecutablePath: String
    public var targetPath: String?
    public var sourcePathCount: Int
    public var createdPaths: [String]
    public var clipboardResultKind: FinderClipboardResultKind?
    public var userMessage: String?
    public var errorMessage: String?

    public init(
        schemaVersion: Int = FinderCommandExecutionRuntimeState.currentSchemaVersion,
        generatedAt: Date = Date(),
        requestID: UUID,
        kind: FinderCommandKind,
        status: FinderCommandExecutionRuntimeStatus,
        startedAt: Date,
        completedAt: Date?,
        agentProcessID: Int32,
        agentBundleIdentifier: String,
        agentBundlePath: String,
        agentExecutablePath: String,
        targetPath: String?,
        sourcePathCount: Int,
        createdPaths: [String] = [],
        clipboardResultKind: FinderClipboardResultKind? = nil,
        userMessage: String? = nil,
        errorMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.requestID = requestID
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.agentProcessID = agentProcessID
        self.agentBundleIdentifier = agentBundleIdentifier
        self.agentBundlePath = agentBundlePath
        self.agentExecutablePath = agentExecutablePath
        self.targetPath = targetPath
        self.sourcePathCount = sourcePathCount
        self.createdPaths = createdPaths
        self.clipboardResultKind = clipboardResultKind
        self.userMessage = userMessage
        self.errorMessage = errorMessage
    }
}

public struct FinderCommandExecutionRuntimeStateStore: Sendable {
    public let stateURL: URL

    public init(
        stateURL: URL = URL(fileURLWithPath: ArcKitConstants.finderCommandExecutionRuntimeStatePath)
    ) {
        self.stateURL = stateURL
    }

    public func save(_ state: FinderCommandExecutionRuntimeState) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 命令耗时可能不足一秒；ISO 8601 默认编码会丢失小数秒，导致安装态真值无法严格往返。
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    public func load() throws -> FinderCommandExecutionRuntimeState {
        let data = try ArcKitBoundedFileReader.read(
            from: stateURL,
            maximumBytes: 1 * 1_024 * 1_024
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(FinderCommandExecutionRuntimeState.self, from: data)
        try validate(state)
        return state
    }

    private func validate(_ state: FinderCommandExecutionRuntimeState) throws {
        guard state.schemaVersion == FinderCommandExecutionRuntimeState.currentSchemaVersion else {
            throw ValidationError.schemaMismatch(
                expected: FinderCommandExecutionRuntimeState.currentSchemaVersion,
                actual: state.schemaVersion
            )
        }
        guard state.agentProcessID > 0,
              state.agentBundleIdentifier == ArcKitConstants.runtimeHostBundleIdentifier,
              state.agentBundlePath == ArcKitConstants.installedRuntimeHostPath,
              state.agentExecutablePath == ArcKitConstants.installedRuntimeHostExecutablePath
        else {
            throw ValidationError.invalidAgentIdentity
        }
        guard state.sourcePathCount >= 0,
              state.targetPath.map({ $0.hasPrefix("/") }) ?? true,
              state.createdPaths.allSatisfy({ $0.hasPrefix("/") }),
              state.generatedAt >= state.startedAt
        else {
            throw ValidationError.invalidPayload
        }
        switch state.status {
        case .started:
            guard state.completedAt == nil,
                  state.errorMessage == nil,
                  state.createdPaths.isEmpty,
                  state.clipboardResultKind == nil,
                  state.userMessage == nil
            else {
                throw ValidationError.invalidLifecycle
            }
        case .succeeded:
            guard let completedAt = state.completedAt,
                  completedAt >= state.startedAt,
                  state.errorMessage == nil
            else {
                throw ValidationError.invalidLifecycle
            }
        case .cancelled:
            guard let completedAt = state.completedAt,
                  completedAt >= state.startedAt,
                  state.errorMessage == nil,
                  state.createdPaths.isEmpty,
                  state.clipboardResultKind == nil,
                  let userMessage = state.userMessage,
                  !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ValidationError.invalidLifecycle
            }
        case .failed:
            guard let completedAt = state.completedAt,
                  completedAt >= state.startedAt,
                  let errorMessage = state.errorMessage,
                  !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  state.createdPaths.isEmpty,
                  state.clipboardResultKind == nil
            else {
                throw ValidationError.invalidLifecycle
            }
        }
    }

    public enum ValidationError: Error, LocalizedError {
        case schemaMismatch(expected: Int, actual: Int)
        case invalidAgentIdentity
        case invalidPayload
        case invalidLifecycle

        public var errorDescription: String? {
            switch self {
            case let .schemaMismatch(expected, actual):
                L10n.string(.Finder.executionStateSchemaMismatch(String(describing: expected), String(describing: actual)))
            case .invalidAgentIdentity:
                L10n.string(.Finder.executionStateInvalidIdentity)
            case .invalidPayload:
                L10n.string(.Finder.executionStateInvalidParameters)
            case .invalidLifecycle:
                L10n.string(.Finder.executionStateInvalidFinderCommandRuntimeLifecycle)
            }
        }
    }
}
