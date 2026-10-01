import ArcKitPlatform
import Foundation
import ServiceManagement

struct RuntimeServiceRegistrationSnapshot: Equatable, Sendable {
    var mainAppShouldRestore: Bool
    var hostShouldRestore: Bool
}

enum RuntimeHostRegistrationError: LocalizedError {
    case failure(String)
    var errorDescription: String? {
        switch self { case let .failure(message): message }
    }
}

enum RuntimeHostRegistrationAction: Equatable { case keepEnabled, waitForApproval, register }

/// 系统副作用集中在此边界；协调器测试不依赖测试 Bundle 路径绕过真实注册。
@MainActor
protocol RuntimeHostSystem {
    var isInstalled: Bool { get }
    var isRunning: Bool { get }
    func save(_ session: RuntimeHostSession) throws
    func removeSession() throws
    func ensureRegistered() throws
    func unregisterHost() throws
    func waitUntilStopped() async -> Bool
    func registrationSnapshot() -> RuntimeServiceRegistrationSnapshot
    func unregisterMainApp() throws
    func restoreRegistration(_ snapshot: RuntimeServiceRegistrationSnapshot) throws
    func invalidateFinderSnapshot()
}

@MainActor
struct InstalledRuntimeHostSystem: RuntimeHostSystem {
    private var service: SMAppService { .agent(plistName: "com.archalo.arckit.runtime-host.plist") }
    var isInstalled: Bool { Bundle.main.bundleURL.standardizedFileURL.path == ArcKitConstants.installedAppPath }
    var isRunning: Bool { RuntimeHostLaunchJobProbe.isRunning() }
    func save(_ session: RuntimeHostSession) throws { try session.save() }
    func removeSession() throws { try RuntimeHostSession.remove() }

    func ensureRegistered() throws {
        guard isInstalled else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostInstalledArcKitManage)) }
        // 旧包必须在覆盖前自行注销；不能在新版本里维持两套恢复机制。
        for label in ["com.archalo.arckit.finder-agent", "com.archalo.arckit.window-agent", "com.archalo.arckit.mouse-agent"] {
            guard RuntimeHostLaunchJobProbe.waitUntilStopped(label: label, timeout: 0) else {
                throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostOldBackgroundComponentsRemainUpgradeUsing(String(describing: label))))
            }
        }
        switch Self.registrationAction(for: service.status) {
        case .keepEnabled: return
        case .waitForApproval: throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostAllowArcKitBackgroundItem))
        case .register:
            try service.register()
            guard service.status == .enabled else { throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostExecutionDenied)) }
        }
    }

    nonisolated static func registrationAction(for status: SMAppService.Status) -> RuntimeHostRegistrationAction {
        switch status {
        case .enabled: .keepEnabled
        case .requiresApproval: .waitForApproval
        case .notRegistered, .notFound: .register
        @unknown default: .waitForApproval
        }
    }

    func unregisterHost() throws {
        if service.status != .notRegistered && service.status != .notFound { try service.unregister() }
    }

    func waitUntilStopped() async -> Bool {
        // launchctl 的有限等待不能占用主线程，退出与卸载共用相同证据标准。
        await Task.detached { RuntimeHostLaunchJobProbe.waitUntilStopped() }.value
    }

    func registrationSnapshot() -> RuntimeServiceRegistrationSnapshot {
        RuntimeServiceRegistrationSnapshot(mainAppShouldRestore: shouldRestore(SMAppService.mainApp.status),
                                           hostShouldRestore: shouldRestore(service.status))
    }

    func unregisterMainApp() throws {
        if shouldRestore(SMAppService.mainApp.status) { try SMAppService.mainApp.unregister() }
    }

    func restoreRegistration(_ snapshot: RuntimeServiceRegistrationSnapshot) throws {
        if snapshot.hostShouldRestore, !shouldRestore(service.status) { try service.register() }
        guard !snapshot.hostShouldRestore || shouldRestore(service.status) else {
            throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostBackgroundRegistrationRecoveryIncomplete))
        }
        if snapshot.mainAppShouldRestore, !shouldRestore(SMAppService.mainApp.status) { try SMAppService.mainApp.register() }
        guard !snapshot.mainAppShouldRestore || shouldRestore(SMAppService.mainApp.status) else {
            throw RuntimeHostRegistrationError.failure(L10n.string(.Runtime.hostLaunchLoginRecoveryIncomplete))
        }
    }

    private func shouldRestore(_ status: SMAppService.Status) -> Bool { status == .enabled || status == .requiresApproval }

    func invalidateFinderSnapshot() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ArcKitConstants.finderSnapshotChangedDistributedNotificationName),
            object: nil, userInfo: nil, deliverImmediately: true)
    }
}
