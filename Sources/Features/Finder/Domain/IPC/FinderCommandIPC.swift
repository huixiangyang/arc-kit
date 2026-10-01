import ArcKitPlatform
import Foundation

public struct FinderCommandAcceptance: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var acceptedAt: Date
    public var agentProcessID: Int32
    public var agentBundleIdentifier: String
    public var agentBundlePath: String

    public init(
        requestID: UUID,
        acceptedAt: Date = Date(),
        agentProcessID: Int32,
        agentBundleIdentifier: String,
        agentBundlePath: String
    ) {
        self.requestID = requestID
        self.acceptedAt = acceptedAt
        self.agentProcessID = agentProcessID
        self.agentBundleIdentifier = agentBundleIdentifier
        self.agentBundlePath = agentBundlePath
    }

    public var isInstalledFinderAgent: Bool {
        agentProcessID > 0
            && agentBundleIdentifier == ArcKitConstants.runtimeHostBundleIdentifier
            && agentBundlePath == ArcKitConstants.installedRuntimeHostPath
    }
}

public enum FinderCommandIPC {
    public static func postSnapshotChanged(_ snapshot: FinderExtensionSnapshot) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ArcKitConstants.finderSnapshotChangedDistributedNotificationName),
            object: "\(snapshot.schemaVersion)",
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func postFinderExtensionRuntimeStateRequest(requestID: UUID, reason: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ArcKitConstants.finderExtensionRuntimeStateRequestDistributedNotificationName),
            object: reason,
            userInfo: ["requestID": requestID.uuidString],
            deliverImmediately: true
        )
    }
}
