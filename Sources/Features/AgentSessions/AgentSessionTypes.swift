import ArcKitPlatform
import Foundation

struct AgentSessionKey: Codable, Hashable, Sendable {
    let sourceID: UUID
    let sessionID: String
    var value: String { sourceID.uuidString + ":" + sessionID }
}

struct CodexLinkedAttachment: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let identityKey: String
    let payload: String
    let createdAt: Int64
}

struct AgentSessionMetadata: Codable, Equatable, Sendable {
    var sessionID: String
    var title: String
    var project: String
    var createdAt: Date
    var modifiedAt: Date
    var sourceByteCount: Int = 0
    var cliVersion: String
    var historyMode: String
    var archived: Bool
    var parentID: String?
    var forkedFromID: String?
    var childIDs: [String]
    var linkedAttachments: [CodexLinkedAttachment] = []
    var pinned: Bool
    var relativePath: String
    var modelProvider: String
}

struct AgentSessionAttachment: Codable, Equatable, Sendable {
    var originalPath: String
    var data: Data
}

struct AgentSessionPayload: Codable, Equatable, Sendable {
    var format = 1
    var sourceID: UUID
    var sourceName: String
    var capturedAt: Date
    var metadata: AgentSessionMetadata
    var rollout: Data
    var attachments: [AgentSessionAttachment]
    var historyProjection: CodexHistoryProjection?
    var missingProjection = false
    var missingAttachments: [String]
    var missingRelatedIDs: [String] = []
    var incompleteBytes: Int
    var changedDuringRead: Bool
    var key: AgentSessionKey { .init(sourceID: sourceID, sessionID: metadata.sessionID) }
    var isComplete: Bool { incompleteBytes == 0 && !changedDuringRead && missingAttachments.isEmpty && missingRelatedIDs.isEmpty && !missingProjection }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
    func validated() throws -> Self {
        guard format == 1, UUID(uuidString: metadata.sessionID) != nil,
              metadata.parentID.map({ UUID(uuidString: $0) != nil }) ?? true,
              metadata.forkedFromID.map({ UUID(uuidString: $0) != nil }) ?? true,
              metadata.childIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              ["legacy", "paginated"].contains(metadata.historyMode),
              CodexSessionAdapter.isRolloutPath(metadata.relativePath), metadata.relativePath.hasSuffix(metadata.sessionID + ".jsonl"),
              missingRelatedIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              !rollout.isEmpty, rollout.count <= CodexSessionAdapter.maximumRolloutBytes,
              incompleteBytes >= 0, attachments.count <= 256,
              Set(attachments.map(\.originalPath)).count == attachments.count,
              attachments.allSatisfy({ $0.originalPath.hasPrefix("/") && $0.data.count <= CodexSessionAdapter.maximumAttachmentBytes }) else { throw AgentSessionError.invalidArchive }
        let parsed = try CodexSessionAdapter.parse(rollout)
        guard parsed.id == metadata.sessionID, parsed.mode == metadata.historyMode, parsed.completeLength == rollout.count else { throw AgentSessionError.invalidArchive }
        if let historyProjection, !historyProjection.matches(sessionID: metadata.sessionID, byteCount: rollout.count) { throw AgentSessionError.invalidArchive }
        return self
    }
}

struct AgentSessionVersion: Identifiable, Codable, Sendable {
    let id: UUID
    let key: AgentSessionKey
    let capturedAt: Date
    let metadata: AgentSessionMetadata
    let relativePath: String
    let byteCount: Int64
    let complete: Bool
    var retained: Bool
}

struct AgentSessionRow: Identifiable, Sendable {
    let key: AgentSessionKey
    var metadata: AgentSessionMetadata
    var sourceName: String
    var sourcePath: String?
    var latest: AgentSessionVersion?
    var sourceMissing: Bool
    var issue: String?
    var id: String { key.value }
    var hasChanges: Bool { latest == nil || metadata.modifiedAt > latest!.metadata.modifiedAt || metadata != latest!.metadata }
}

struct AgentSessionScan: Sendable {
    var rows: [AgentSessionRow] = []
    var sourceErrors: [UUID: String] = [:]
    var scannedSources: Set<UUID> = []
}

struct AgentTranscriptEntry: Identifiable, Sendable {
    let id: Int
    let kind: String
    let text: String
}

enum AgentSessionError: LocalizedError {
    case invalidArchive, unsupportedFormat, changedSource, capacity, password, passwordShort, busyTarget, nativeUnavailable, conflict, interruptedRestore, missingRelated
    case detail(String)
    var errorDescription: String? {
        switch self {
        case .invalidArchive: L10n.string(.AgentSessions.errorArchive)
        case .unsupportedFormat: L10n.string(.AgentSessions.errorFormat)
        case .changedSource: L10n.string(.AgentSessions.errorChanged)
        case .capacity: L10n.string(.AgentSessions.errorCapacity)
        case .password: L10n.string(.AgentSessions.errorPassword)
        case .passwordShort: L10n.string(.AgentSessions.errorPasswordShort)
        case .busyTarget: L10n.string(.AgentSessions.errorBusyTarget)
        case .nativeUnavailable: L10n.string(.AgentSessions.errorNative)
        case .conflict: L10n.string(.AgentSessions.errorConflict)
        case .interruptedRestore: L10n.string(.AgentSessions.errorInterrupted)
        case .missingRelated: L10n.string(.AgentSessions.errorRelated)
        case .detail(let message): message
        }
    }
}
