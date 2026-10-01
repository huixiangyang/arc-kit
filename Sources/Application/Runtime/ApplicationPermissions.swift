import AppKit
import ArcKitPlatform
import Combine
import FinderSync
import Foundation
import ServiceManagement

/// 系统开关的事实与进程运行状态分开保存；后台获准运行不代表当前有 PID。
enum ServiceAuthorization: Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound, unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

struct SystemAuthorizationSnapshot: Equatable {
    let checkedAt: Date
    let background: ServiceAuthorization
    let finderEnabled: Bool?
    let menuInputAllowed: Bool
    func isCurrent(at now: Date) -> Bool { (0...30).contains(now.timeIntervalSince(checkedAt)) }
}

/// 应用运行实例唯一的权限证据源。没有 TCC 数据库读取、持久化授权值或预先索要所有权限。
@MainActor
public final class ApplicationPermissions: ObservableObject {
    @Published private(set) var runtime: RuntimePermissionSnapshot?
    @Published private(set) var system: SystemAuthorizationSnapshot?
    @Published private(set) var requestFailure: String?
    @Published private(set) var isRequesting = false
    @Published private(set) var isAwaitingApproval = false
    let isPreview: Bool

    public init(isPreview: Bool = true) { self.isPreview = isPreview }

    func refreshSystem() {
        guard !isPreview, Bundle.main.bundleURL.standardizedFileURL.path == ArcKitConstants.installedAppPath else { return }
        system = .init(checkedAt: Date(),
            background: .init(SMAppService.agent(plistName: "com.archalo.arckit.runtime-host.plist").status),
            finderEnabled: FinderExtensionStatusService.installedExtensionFileExists() ? FIFinderSyncController.isExtensionEnabled : nil,
            menuInputAllowed: ProcessPermissions.canListenToInput())
    }

    func receiveSystem(_ snapshot: SystemAuthorizationSnapshot) { system = snapshot }

    func receive(_ snapshot: RuntimePermissionSnapshot) {
        runtime = snapshot
        requestFailure = nil
        if snapshot.accessibilityTrusted { isAwaitingApproval = false }
    }
    func invalidateRuntime() {
        runtime = nil; isRequesting = false; isAwaitingApproval = false; requestFailure = nil
    }
    func beginRequest() { isRequesting = true; requestFailure = nil }
    func finishRequest(error: String? = nil) {
        isRequesting = false
        requestFailure = error
        // Host 回执只说明申请命令完成；系统授权流程可能还在等待用户操作。
        isAwaitingApproval = error == nil && accessibilityEvidence() == .denied
    }
    func finishApprovalWait() { isAwaitingApproval = false }

    func accessibilityEvidence(now: Date = Date()) -> PermissionEvidence {
        guard let runtime, runtime.isCurrent(at: now) else { return .unknown }
        return runtime.accessibilityTrusted ? .granted : .denied
    }

    func backgroundBlocker(now: Date = Date()) -> FeatureHealth? {
        guard let system, system.isCurrent(at: now) else { return nil }
        if system.background == .requiresApproval {
            return .init(state: .blocked, title: L10n.string(.Runtime.permissionsBackgroundDenied), detail: L10n.string(.Runtime.permissionsAllowArcKitBackgroundItem),
                         action: .loginItems, checkedAt: system.checkedAt)
        }
        return nil
    }

    func windowHealth(_ service: FeatureHealth, required: Bool, menuBarVisible: Bool, now: Date = Date()) -> FeatureHealth {
        guard required, !isPreview else { return service }
        if let blocked = backgroundBlocker(now: now) { return blocked }
        if service.state == .ready || service.state == .partial,
           menuInputHealth(required: menuBarVisible, now: now).permission == .denied {
            return .init(state: .partial, title: L10n.string(.Runtime.permissionsMenuBarLayoutsUnavailable), detail: L10n.string(.Runtime.permissionsAllowInputMonitoringArcKit),
                         permission: service.permission, action: .inputMonitoring, checkedAt: system?.checkedAt)
        }
        return service
    }

    func accessibilityHealth(required: Bool, now: Date = Date()) -> FeatureHealth {
        if isPreview { return .init(state: .preview, title: L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Runtime.permissionsDebugAccessibilityHint)) }
        guard required else { return .init(state: .disabled, title: L10n.string(.Runtime.permissionsNotRequired), detail: L10n.string(.Runtime.permissionsWindowsMouseOffExistingSystem), permission: .notRequired) }
        if let blocker = backgroundBlocker(now: now) { return blocker }
        if isRequesting { return .init(state: .unknown, title: L10n.string(.Runtime.permissionsRequesting), detail: L10n.string(.Runtime.permissionsRequestedArcKitHost)) }
        if isAwaitingApproval {
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsWaitingSystemPermission), detail: L10n.string(.Runtime.permissionsAllowArcKitHostSystem),
                         action: .accessibilitySettings)
        }
        if let requestFailure {
            return .init(state: .blocked, title: L10n.string(.Runtime.permissionsRequestIncomplete), detail: requestFailure, action: .refresh)
        }
        switch accessibilityEvidence(now: now) {
        case .unknown, .notRequired:
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsUnconfirmed), detail: L10n.string(.Runtime.permissionsValidPermissionResponseCurrentMissing), action: .refresh)
        case .denied:
            return .init(state: .blocked, title: L10n.string(.Runtime.permissionsNotGranted), detail: L10n.string(.Runtime.permissionsUsedWindowControlScrollingGestures),
                         permission: .denied, action: .accessibility, checkedAt: runtime?.checkedAt)
        case .granted:
            return .init(state: .ready, title: L10n.string(.Runtime.permissionsGranted), detail: L10n.string(.Runtime.permissionsArcKitHostSeeFeatureStatus),
                         permission: .granted, action: .accessibilitySettings, checkedAt: runtime?.checkedAt)
        }
    }

    func menuInputHealth(required: Bool, now: Date = Date()) -> FeatureHealth {
        if isPreview { return .init(state: .preview, title: L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Runtime.permissionsDebugInputHint)) }
        guard required else { return .init(state: .disabled, title: L10n.string(.Runtime.permissionsNotRequired), detail: L10n.string(.Runtime.permissionsMenuBarClickNotRequired), permission: .notRequired) }
        guard let system, system.isCurrent(at: now) else {
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsUnconfirmed), detail: L10n.string(.Runtime.permissionsInputMonitoringCheckResultMissing), action: .refresh)
        }
        return .init(state: system.menuInputAllowed ? .ready : .blocked,
                     title: system.menuInputAllowed ? L10n.string(.Runtime.permissionsMonitoringAllowed) : L10n.string(.Runtime.permissionsDenied),
                     detail: L10n.string(.Runtime.permissionsGrantAccessArcKitReadsMouse),
                     permission: system.menuInputAllowed ? .granted : .denied,
                     action: system.menuInputAllowed ? .inputMonitoringSettings : .inputMonitoring, checkedAt: system.checkedAt)
    }

    func finderHealth(required: Bool, now: Date = Date()) -> FeatureHealth {
        if isPreview { return .init(state: .preview, title: L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Runtime.permissionsDebugExtensionHint)) }
        guard required else { return .init(state: .disabled, title: L10n.string(.Runtime.permissionsNotRequired), detail: L10n.string(.Runtime.permissionsFinderOffSystemExtensionSwitch), permission: .notRequired) }
        guard let system, system.isCurrent(at: now), let enabled = system.finderEnabled else {
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsUnconfirmed), detail: L10n.string(.Runtime.permissionsExtensionSwitchResultInstallationMissing), action: .refresh)
        }
        return .init(state: enabled ? .ready : .blocked, title: enabled ? L10n.string(.Runtime.permissions) : L10n.string(.Runtime.permissionsOff),
                     detail: L10n.string(.Runtime.permissionsAllowsArcKitProvideFinderMenus),
                     permission: enabled ? .granted : .denied, action: .extensionSettings, checkedAt: system.checkedAt)
    }

    func backgroundHealth(required: Bool, now: Date = Date()) -> FeatureHealth {
        if isPreview { return .init(state: .preview, title: L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Runtime.permissionsDebugHostHint)) }
        guard required else { return .init(state: .disabled, title: L10n.string(.Runtime.permissionsNotRequired), detail: L10n.string(.Runtime.permissionsFinderWindowsMouseAllOff), permission: .notRequired) }
        guard let system, system.isCurrent(at: now) else {
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsUnconfirmed), detail: L10n.string(.Runtime.permissionsValidBackgroundRegistrationResultMissing), action: .refresh)
        }
        switch system.background {
        case .enabled:
            return .init(state: .ready, title: L10n.string(.Runtime.permissionsAllowed), detail: L10n.string(.Runtime.permissionsUsedFinderWindowsMouseConfigured),
                         permission: .granted, action: .loginItems, checkedAt: system.checkedAt)
        case .requiresApproval: return backgroundBlocker(now: now)!
        case .notRegistered:
            return .init(state: .blocked, title: L10n.string(.Runtime.permissionsUnregisteredYet), detail: L10n.string(.Runtime.permissionsCheckAgainRestoreBackgroundRegistration), action: .refresh)
        case .notFound:
            return .init(state: .blocked, title: L10n.string(.Runtime.permissionsComponentMissing), detail: L10n.string(.Runtime.permissionsHostMissing))
        case .unknown:
            return .init(state: .unknown, title: L10n.string(.Runtime.permissionsUnconfirmed), detail: L10n.string(.Runtime.permissionsRegistrationUnknown), action: .refresh)
        }
    }
}

/// 系统入口只导航，不申请或重置授权。
enum SystemPrivacySettings {
    enum Pane: String { case accessibility = "Privacy_Accessibility", inputMonitoring = "Privacy_ListenEvent", automation = "Privacy_Automation" }
    @MainActor static func open(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
