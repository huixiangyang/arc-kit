import ArcKitPlatform
import Foundation

/// 当前进程已发布或从可信 XPC 收到的菜单快照。通知只要求刷新，不携带配置。
/// 所有实例共享内存；不再提供文件通道，也不在读取缺失时重建默认菜单。
public final class FinderExtensionSnapshotStore: @unchecked Sendable {
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: FinderExtensionSnapshot?
        private var updatedAt: Date?

        func read() -> (snapshot: FinderExtensionSnapshot?, updatedAt: Date?) {
            lock.lock()
            defer { lock.unlock() }
            return (snapshot, updatedAt)
        }

        func replace(_ snapshot: FinderExtensionSnapshot) {
            lock.lock()
            defer { lock.unlock() }
            self.snapshot = snapshot
            updatedAt = Date()
        }
    }

    private static let memory = Memory()
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.archalo.arckit.finder-snapshot", qos: .utility)
        queue.setSpecific(key: queueKey, value: 1)
        return queue
    }()

    public init() {}

    public func load() -> FinderExtensionSnapshot? { Self.memory.read().snapshot }

    /// 设置提交后的扫描与发布串行执行，旧配置的慢扫描不能反向覆盖新配置。
    public func publish(settings: FinderRuntimeSettings) {
        Self.queue.async {
            let snapshot = FinderExtensionSnapshot.make(
                settings: settings,
                applicationAvailability: { FavoriteApplicationAvailabilityResolver.isAvailable($0) }
            )
            self.publish(snapshot, reason: "committed-settings")
        }
    }

    public func publish(_ snapshot: FinderExtensionSnapshot, reason: String) {
        serialized {
            Self.memory.replace(snapshot)
            ArcKitLog.append("snapshot published reason=\(reason) storage=memory version=\(snapshot.schemaVersion)")
            FinderCommandIPC.postSnapshotChanged(snapshot)
        }
    }

    /// 仅由已验证服务身份、并过滤过期代次的 XPC 回调调用，不再次广播。
    public func receive(_ snapshot: FinderExtensionSnapshot, reason: String) {
        serialized {
            Self.memory.replace(snapshot)
            ArcKitLog.append("snapshot received reason=\(reason) storage=memory version=\(snapshot.schemaVersion)")
        }
    }

    public func latestSnapshotAgeDescription(now: Date = Date()) -> String {
        guard let updatedAt = Self.memory.read().updatedAt else { return L10n.string(.Finder.extensionNotReceived) }
        let seconds = max(0, Int(now.timeIntervalSince(updatedAt)))
        if seconds < 60 { return L10n.string(.Finder.extensionSAgo(String(describing: seconds))) }
        let minutes = seconds / 60
        return minutes < 60 ? L10n.string(.Finder.extensionMAgo(String(describing: minutes))) : L10n.string(.Finder.extensionHAgo(String(describing: minutes / 60)))
    }

    private func serialized(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() }
        else { Self.queue.sync(execute: body) }
    }
}
