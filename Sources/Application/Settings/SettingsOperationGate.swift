import Combine
import Foundation

/// 主线程上的排他门禁。租约只能由持有者释放，避免失败回调误释放后续任务。
@MainActor
final class SettingsOperationGate: ObservableObject {
    enum Kind { case commit, history, transfer, storage, uninstall, termination }
    struct Lease: Equatable {
        fileprivate let id = UUID()
        let kind: Kind
    }
    @Published private var active: Lease?
    var isBusy: Bool { active != nil }

    func begin(_ kind: Kind) throws -> Lease {
        guard active == nil else { throw SettingsBackupError.operationInProgress }
        let lease = Lease(kind: kind)
        active = lease
        return lease
    }

    func owns(_ lease: Lease) -> Bool { active == lease }

    func end(_ lease: Lease) {
        guard owns(lease) else { return }
        active = nil
    }
}
