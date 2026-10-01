import ArcKitFinder
import ArcKitPlatform
import Foundation

/// 在副作用开始前落盘接收身份。Host 崩溃后同一请求只能报告结果未知，不能重放文件操作。
@MainActor
public final class FinderCommandAdmissionStore {
    private struct Record: Codable { var sessionID: UUID; var requests: [UUID: Date] }
    private let sessionID: UUID
    private let fileURL: URL

    public init(sessionID: UUID, fileURL: URL = ArcKitStoragePaths.current.receipts) {
        self.sessionID = sessionID
        self.fileURL = fileURL
    }

    public func accept(_ request: FinderCommandRequest, now: Date = Date()) throws {
        guard now.timeIntervalSince(request.createdAt) >= -5, now.timeIntervalSince(request.createdAt) <= 30 else {
            throw RuntimeAgentIPCError.requestExpired
        }
        var record = Record(sessionID: sessionID, requests: [:])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stored = try JSONDecoder().decode(Record.self, from: ArcKitBoundedFileReader.read(from: fileURL, maximumBytes: 64 * 1024))
            if stored.sessionID == sessionID { record = stored }
        }
        record.requests = record.requests.filter { now.timeIntervalSince($0.value) < 180 }
        guard record.requests[request.id] == nil else {
            throw RuntimeAgentIPCError.remoteFailure(L10n.string(.FinderActions.admissionActionAlreadyAccepted))
        }
        guard record.requests.count < 512 else { throw RuntimeAgentIPCError.remoteFailure(L10n.string(.FinderActions.admissionTooManyFinderOperationsRetryLater)) }
        record.requests[request.id] = now
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ArcKitAtomicFile.writeAtomically(JSONEncoder().encode(record), to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
