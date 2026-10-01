import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation

@MainActor
final class LaunchAtLoginCoordinator {
    private let settingsModel: SettingsModel
    private let loginService: LaunchAtLoginService
    private var hasAppliedLaunchAtLoginSetting = false
    /// 回滚提交不能再次调用系统 API，否则会覆盖原始错误。
    private var pendingLaunchAtLoginRollbackValue: Bool?

    init(settingsModel: SettingsModel, loginService: LaunchAtLoginService) {
        self.settingsModel = settingsModel
        self.loginService = loginService
    }

    func apply(_ settings: AppSettings, previousSettings: AppSettings?) {
        if let rollbackValue = pendingLaunchAtLoginRollbackValue,
           settings.launchAtLoginEnabled == rollbackValue {
            pendingLaunchAtLoginRollbackValue = nil
            return
        }
        if hasAppliedLaunchAtLoginSetting,
           let previousSettings,
           previousSettings.launchAtLoginEnabled == settings.launchAtLoginEnabled {
            return
        }
        hasAppliedLaunchAtLoginSetting = true
        let desiredValue = settings.launchAtLoginEnabled
        let result = loginService.applyLaunchAtLogin(enabled: desiredValue)
        handleLaunchAtLoginResult(
            result,
            desiredValue: desiredValue,
            previousValue: previousSettings?.launchAtLoginEnabled
        )
    }

    func retryLaunchAtLoginChange() {
        guard let desiredValue = loginService.failedLaunchAtLoginDesiredState else {
            loginService.refreshLaunchAtLoginStatus()
            return
        }
        if settingsModel.committedSettings?.launchAtLoginEnabled == desiredValue,
           settingsModel.settings.launchAtLoginEnabled == desiredValue {
            let result = loginService.applyLaunchAtLogin(enabled: desiredValue)
            handleLaunchAtLoginResult(
                result,
                desiredValue: desiredValue,
                previousValue: settingsModel.committedSettings?.launchAtLoginEnabled
            )
            return
        }
        settingsModel.update(actionName: desiredValue ? L10n.string(.App.loginReEnableLaunchLogin) : L10n.string(.App.loginDisableLaunchLoginAgain)) {
            $0.launchAtLoginEnabled = desiredValue
        }
        settingsModel.flush()
    }

    private func handleLaunchAtLoginResult(
        _ result: LaunchAtLoginService.LaunchAtLoginApplyResult,
        desiredValue: Bool,
        previousValue: Bool?
    ) {
        guard case .failed = result else { return }
        let rollbackValue: Bool
        switch loginService.launchAtLoginState {
        case .enabled:
            rollbackValue = true
        case .disabled:
            rollbackValue = false
        case .requiresApproval:
            // 等待系统许可保留已提交的用户意图，不反向关闭或再次注册。
            return
        case .unknown:
            // 状态无法证明时，用户切换操作回到操作前；启动期则不宣称已经启用。
            if let previousValue, previousValue != desiredValue {
                rollbackValue = previousValue
            } else {
                rollbackValue = false
            }
        }
        guard rollbackValue != desiredValue else { return }
        pendingLaunchAtLoginRollbackValue = rollbackValue
        // 系统登录项失败后的双向回滚不是用户操作，不能生成一个可重做的无效状态。
        settingsModel.update(actionName: L10n.string(.App.loginRollBackLaunchLogin), recordsHistory: false) {
            $0.launchAtLoginEnabled = rollbackValue
        }
    }

}
