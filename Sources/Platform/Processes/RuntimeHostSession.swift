import Darwin
import Foundation

/// 仅表示当前 App 实例的运行意图，不修改用户功能偏好。PID 与内核启动时间共同阻止 PID 复用。
public struct RuntimeHostSession: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, processID, startedSeconds, startedMicroseconds }
    public let id: UUID
    public var revision: UInt64 = 0
    public let processID: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public var windowEnabled: Bool = false
    public var mouseEnabled: Bool = false
    public var finderEnabled: Bool = false
    public var needsContinuousRuntime: Bool { windowEnabled || mouseEnabled }
    public var hasEnabledFeatures: Bool { needsContinuousRuntime || finderEnabled }

    public init(windowEnabled: Bool, mouseEnabled: Bool, finderEnabled: Bool) throws {
        guard let identity = Self.identity(of: getpid()) else { throw RuntimeAgentIPCError.connectionFailed(L10n.string(.Platform.sessionIdentityUnavailable)) }
        id = UUID(); processID = getpid()
        startedSeconds = identity.0; startedMicroseconds = identity.1
        self.windowEnabled = windowEnabled; self.mouseEnabled = mouseEnabled; self.finderEnabled = finderEnabled
    }

    public var isOwnerAlive: Bool {
        guard let identity = Self.identity(of: processID) else { return false }
        return identity.0 == startedSeconds && identity.1 == startedMicroseconds
    }

    public static func ownerStartedAt(processID: Int32) -> Date? {
        guard let identity = identity(of: processID) else { return nil }
        return Date(timeIntervalSince1970: Double(identity.0) + Double(identity.1) / 1_000_000)
    }

    private static func identity(of pid: Int32) -> (UInt64, UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    public static var fileURL: URL {
        ArcKitStoragePaths.current.owner
    }

    public func save(to url: URL = Self.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ArcKitAtomicFile.writeAtomically(JSONEncoder().encode(self), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(from url: URL = Self.fileURL) throws -> Self {
        let data = try ArcKitBoundedFileReader.read(from: url, maximumBytes: 8192)
        let session = try JSONDecoder().decode(Self.self, from: data)
        guard session.isOwnerAlive else { throw RuntimeAgentIPCError.connectionFailed(L10n.string(.Platform.sessionMainAppRuntimeSessionEnded)) }
        return session
    }

    public static func remove(from url: URL = Self.fileURL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
