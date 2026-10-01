import ArcKitPlatform
import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginRegistrationStatus: Equatable {
    case requiresApproval
    case enabled
    case notRegistered
    case unknown
}

@MainActor
protocol LaunchAtLoginManaging {
    var status: LaunchAtLoginRegistrationStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// 主 App 登录启动由系统管理；登录后由唯一协调器按需注册 Runtime Host。
@MainActor
struct SMAppServiceLaunchAtLoginManager: LaunchAtLoginManaging {
    var status: LaunchAtLoginRegistrationStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered, .notFound: .notRegistered
        case .requiresApproval: .requiresApproval
        @unknown default: .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 登录启动的系统事实及操作回执，与 Finder 偏好和截图设置分开。
@MainActor
public final class LaunchAtLoginService: ObservableObject {
    public enum LaunchAtLoginState: Equatable {
        case requiresApproval
        case unknown
        case enabled
        case disabled

        var displayName: String {
            switch self {
            case .requiresApproval: L10n.string(.Settings.systemAwaitingSystemPermission)
            case .unknown: L10n.string(.Common.unknown)
            case .enabled: L10n.string(.Common.enabled)
            case .disabled: L10n.string(.Common.off)
            }
        }
    }

    enum LaunchAtLoginApplyResult: Equatable {
        case requiresApproval
        case effective
        case failed(String)
    }

    @Published public private(set) var launchAtLoginState: LaunchAtLoginState = .unknown
    @Published public private(set) var lastLaunchAtLoginError: String?
    @Published public private(set) var failedLaunchAtLoginDesiredState: Bool?
    private let launchAtLoginManager: LaunchAtLoginManaging

    public convenience init() { self.init(manager: SMAppServiceLaunchAtLoginManager()) }

    init(manager: LaunchAtLoginManaging) {
        self.launchAtLoginManager = manager
        refreshLaunchAtLoginStatus()
    }

    @discardableResult
    func applyLaunchAtLogin(enabled: Bool) -> LaunchAtLoginApplyResult {
        let currentStatus = launchAtLoginManager.status
        do {
            if enabled {
                if currentStatus == .enabled {
                    lastLaunchAtLoginError = nil
                    failedLaunchAtLoginDesiredState = nil
                    refreshLaunchAtLoginStatus()
                    return .effective
                }
                // 等待用户批准是已注册状态，反复 register 不会获得授权。
                if currentStatus != .requiresApproval { try launchAtLoginManager.register() }
            } else if currentStatus != .notRegistered {
                // plist 损坏或服务未加载时仍然属于“存在注册痕迹”，关闭操作必须
                // 物理删除它，不能因状态未知而静默跳过。
                try launchAtLoginManager.unregister()
            }
            lastLaunchAtLoginError = nil
            failedLaunchAtLoginDesiredState = nil
        } catch {
            lastLaunchAtLoginError = error.localizedDescription
            failedLaunchAtLoginDesiredState = enabled
            ArcKitLog.append("launch at login update failed error=\(error.localizedDescription)")
            refreshLaunchAtLoginStatus()
            return .failed(error.localizedDescription)
        }

        refreshLaunchAtLoginStatus()
        if enabled, launchAtLoginState == .requiresApproval { return .requiresApproval }
        if enabled, launchAtLoginState != .enabled {
            let message = L10n.string(.Settings.systemLoginEnableUnconfirmed(String(describing: launchAtLoginState.displayName)))
            lastLaunchAtLoginError = message
            failedLaunchAtLoginDesiredState = true
            ArcKitLog.append("launch at login ineffective desired=enabled state=\(launchAtLoginState.displayName)")
            return .failed(message)
        }
        if !enabled, launchAtLoginState != .disabled {
            let message = L10n.string(.Settings.systemLoginDisableUnconfirmed(String(describing: launchAtLoginState.displayName)))
            lastLaunchAtLoginError = message
            failedLaunchAtLoginDesiredState = false
            ArcKitLog.append("launch at login ineffective desired=disabled state=\(launchAtLoginState.displayName)")
            return .failed(message)
        }
        failedLaunchAtLoginDesiredState = nil
        return .effective
    }

    public func openLoginItemsSettings() {
        launchAtLoginManager.openSystemSettings()
    }

    func refreshLaunchAtLoginStatus() {
        let status = launchAtLoginManager.status
        if status == .requiresApproval {
            launchAtLoginState = .requiresApproval
        } else if status == .enabled {
            launchAtLoginState = .enabled
        } else if status == .notRegistered {
            launchAtLoginState = .disabled
        } else {
            launchAtLoginState = .unknown
        }
    }
}
