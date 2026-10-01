import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
@preconcurrency import AppKit
import Combine
import Foundation

/// 界面与应用生命周期组合根；后台编排由 ApplicationRuntime 持有。
@MainActor
public final class AppController: NSObject, NSMenuItemValidation {
    private let settingsModel = SettingsModel()
    private lazy var dataModel = DataManagementModel(settingsModel: settingsModel)
    private let loginService = LaunchAtLoginService()
    private lazy var menuBarController = MenuBarController(actions: menuBarActions, prepare: { [weak self] application, completion in
        guard let self else { completion(.unavailable(L10n.string(.App.applicationWindowServiceEnded))); return }
        runtime.mouseService.refresh()
        runtime.windowService.captureWindowTarget(application: application) { [weak self] capture in
            self?.refreshMenuBar()
            completion(capture)
        }
    })
    private let systemEnhancementService = SystemEnhancementService()
    private let wallpaperModel = WallpaperModel(library: WallpaperLibrary(database: ApplicationStorage.database))
    private let backgroundModel = AppBackgroundModel(store: AppBackgroundStore(database: ApplicationStorage.database))
    private lazy var runtime = ApplicationRuntime(settingsModel: settingsModel)
    private lazy var loginCoordinator = LaunchAtLoginCoordinator(settingsModel: settingsModel, loginService: loginService)
    private let supportDiagnosticsService = SupportDiagnosticsService()
    private lazy var dataTransfer = DataTransferCoordinator(dataModel: dataModel)
    private lazy var diagnosticExport = SupportDiagnosticsCoordinator(
        runtime: runtime,
        loginService: loginService,
        exportService: supportDiagnosticsService
    )
    private let finderDiagnostics = FinderDiagnosticsWindowController()
    private let uninstallService = ArcKitUninstallService()
    private var isUninstalling = false
    private var uninstallCompleted = false
    private var isRepairingFinder = false
    private let updateService = ArcKitUpdateService()
    private let windowFailureHUD = WindowFailureHUDPresenter()
    private let healthModel = AppRuntimeHealthModel()
    private lazy var mainWindowController = MainWindowController(
        refreshFinder: { [unowned self] in healthModel.refreshAfterRepair() },
        setWindowVisible: { [unowned self] in backgroundModel.setWindowVisible($0) }
    ) { [unowned self] navigation in
        ApplicationWorkspace(
            model: settingsModel,
            dataModel: dataModel,
            loginService: loginService,
            systemService: systemEnhancementService,
            wallpaperModel: wallpaperModel,
            backgroundModel: backgroundModel,
            mouseService: runtime.mouseService,
            windowService: runtime.windowService,
            hotKeyService: runtime.hotKeyService,
            supportDiagnosticsService: supportDiagnosticsService,
            uninstallService: uninstallService,
            updateService: updateService,
            healthModel: healthModel,
            permissions: runtime.permissions,
            navigation: navigation,
            actions: mainWindowActions
        )
    }
    private var settings: AppSettings { runtime.committedSettings ?? .defaults }
    private var settingsObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var settingsWindowTarget = WindowTargetSession()
    private var serviceCancellables: Set<AnyCancellable> = []
    /// 合并同一轮配置与运行快照通知；只更新状态，不重建浮层。
    private var menuBarRefreshWorkItem: DispatchWorkItem?
    /// 登录项启动时始终保持 accessory；只有用户显式打开后才允许恢复 Dock 偏好。
    private var launchMode: ArcKitApplicationLaunchMode

    public init(launchMode: ArcKitApplicationLaunchMode) {
        self.launchMode = launchMode
        super.init()
        dataModel.beforeStorageOperation = { [weak self] restoring in
            guard let self else { return }
            await wallpaperModel.finishPendingChanges()
            await backgroundModel.finishPendingChanges()
            guard !wallpaperModel.channels.busy else { throw CocoaError(.userCancelled) }
            if case .failed(let message) = backgroundModel.persistenceState { throw ArcKitDatabaseError.message(message) }
            if restoring {
                wallpaperModel.stop()
                runtime.stop()
                try await runtime.host.unregisterForQuit()
            }
        }
        dataModel.afterStorageOperation = { [weak self] restoring in
            guard let self, restoring else { return }
            backgroundModel.reload()
            wallpaperModel.start()
            runtime.start()
        }
        ApplicationMenuBuilder.install(target: self)
        runtime.windowService.userFeedbackHandler = { [weak self] message in
            self?.windowFailureHUD.show(message: message)
        }
        observeSettingsChanges()
        observeAppActivation()
        observeScreenParameters()
        refreshMenuBar()
        runtime.stateDidChange = { [weak self] in self?.scheduleMenuBarRefresh() }
        runtime.settingsDidCommit = { [weak self] previous, current in
            guard let self else { return }
            if previous == nil || previous?.language != current.language {
                L10n.configure(current.language)
                ApplicationMenuBuilder.install(target: self)
                settingsModel.objectWillChange.send()
                scheduleMenuBarRefresh()
            }
            // 普通开关提交不能 deactivate 应用，否则 transient 浮层会被系统收起。
            if previous == nil || previous?.showDockIcon != current.showDockIcon {
                applyActivationPolicy()
            }
            loginCoordinator.apply(current, previousSettings: previous)
        }
        settingsModel.objectWillChange.sink { [weak self] _ in
            self?.scheduleMenuBarRefresh()
        }.store(in: &serviceCancellables)
        runtime.start()
        wallpaperModel.start()
        updateService.start()
        if launchMode == .interactive {
            showMainWindow()
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let appActivationObserver { NotificationCenter.default.removeObserver(appActivationObserver) }
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsRepository.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let source = notification.object as? SettingsRepository
            Task { @MainActor in
                guard let self,
                      !self.settingsModel.isOwnRepository(source)
                else { return }
                self.settingsModel.reload()
            }
        }
    }

    private func observeAppActivation() {
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.runtime.refreshRuntimeState()
                self?.loginService.refreshLaunchAtLoginStatus()
            }
        }
    }

    private func observeScreenParameters() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleMenuBarRefresh()
            }
        }
    }

    private var mainWindowActions: ApplicationActions {
        ApplicationActions(
            health: RuntimeHealthActions(
                requestAccessibilityPermission: { [weak self] in self?.requestAccessibilityPermission() },
                openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
                requestMenuInputPermission: { [weak self] in self?.runtime.requestMenuInputPermission() },
                openInputMonitoringSettings: { SystemPrivacySettings.open(.inputMonitoring) },
                openAutomationSettings: { SystemPrivacySettings.open(.automation) },
                openExtensionSettings: { [weak self] in self?.openExtensionSettings() },
                showFinderExtensionDiagnostics: { [weak self] in self?.showFinderExtensionDiagnostics() },
                repairFinderExtension: { [weak self] completion in self?.performFinderRepair(completion: completion) },
                openLoginItemsSettings: { [weak self] in self?.loginService.openLoginItemsSettings() },
                refreshRuntimeState: { [weak self] in self?.runtime.refreshRuntimeState(retryConnection: true) }
            ),
            general: GeneralSettingsActions(
                toggleHiddenFiles: { [weak self] in self?.systemEnhancementService.toggleHiddenFilesAndRestartFinder() },
                chooseScreenshotLocation: { [weak self] in
                    self?.systemEnhancementService.chooseScreenshotLocation()
                },
                resetScreenshotLocation: { [weak self] in
                    self?.systemEnhancementService.resetScreenshotLocation()
                },
                openLoginItemsSettings: { [weak self] in self?.loginService.openLoginItemsSettings() },
                retryLaunchAtLoginChange: { [weak self] in self?.loginCoordinator.retryLaunchAtLoginChange() }
            ),
            data: DataManagementActions(
                exportBackup: { [weak self] scope in self?.dataTransfer.exportBackup(scope: scope) },
                revealExportedBackup: { [weak self] in self?.dataTransfer.revealExportedBackup() },
                restoreBackup: { [weak self] in self?.dataTransfer.restoreBackup() },
                exportSupportDiagnostics: { [weak self] in self?.diagnosticExport.exportReport() },
                uninstallArcKit: { [weak self] deleteData in self?.uninstallArcKit(deleteData: deleteData) }
            ),
            window: WindowCommandActions(
                prepareQuickFind: { [weak self] in self?.captureSettingsWindowTarget() },
                performWindowAction: { [weak self] action in self?.performWindowAction(action) }
            )
        )
    }

    private var menuBarActions: MenuBarPanelActions {
        MenuBarPanelActions(
            performWindow: { [weak self] action, targetID in
                self?.runtime.windowService.perform(action, targetID: targetID)
            },
            setWindowEnabled: { [weak self] in self?.setWindowManagementEnabled($0) },
            setMouseEnabled: { [weak self] in self?.setMouseEnhancementEnabled($0) },
            setFinderEnabled: { [weak self] in self?.setFinderContextMenuEnabled($0) },
            openSection: { [weak self] in self?.showMainWindow(section: $0) },
            retrySave: { [weak self] in self?.settingsModel.flush(); self?.refreshMenuBar() },
            checkState: { [weak self] in self?.checkMenuBarState() },
            quit: { [weak self] in self?.quit() }
        )
    }

    private func scheduleMenuBarRefresh() {
        menuBarRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refreshMenuBar() }
        menuBarRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func refreshMenuBar() {
        let state = menuBarController.state
        state.settings = settings
        state.windowHealth = FeatureHealthAssessment.window(settings: settings.windowManagement,
            snapshot: runtime.windowService.runtimeSnapshot, receivedAt: runtime.windowService.lastResponseAt)
        state.mouseHealth = FeatureHealthAssessment.mouse(settings: settings.mouseEnhancement,
            snapshot: runtime.mouseService.runtimeSnapshot, receivedAt: runtime.mouseService.lastResponseAt)
        if let blocked = runtime.permissions.backgroundBlocker() {
            if settings.windowManagement.isEnabled { state.windowHealth = blocked }
            if settings.mouseEnhancement.isEnabled { state.mouseHealth = blocked }
        }
        state.windowHealth = runtime.permissions.windowHealth(state.windowHealth, required: settings.windowManagement.isEnabled, menuBarVisible: settings.showMenuBarIcon)
        // 快捷键冲突不影响手动布局；权限证据与 AX 可操作性仍必须有效。
        state.windowActionsAvailable = settings.windowManagement.isEnabled
            && state.windowHealth.permission == .granted && runtime.windowService.accessibilityOperational
        state.screenCount = NSScreen.screens.count
        if case let .failed(message) = settingsModel.persistenceState { state.saveFailure = message }
        else { state.saveFailure = nil }
        // 只应用已提交选择；初次加载失败仍保留诊断入口，不根据未保存草稿隐藏图标。
        let isVisible = runtime.committedSettings?.showMenuBarIcon ?? !settingsModel.isLoading
        menuBarController.refreshPresentation(isVisible: isVisible)
    }

    private func applyActivationPolicy(activate: Bool = false) {
        guard launchMode == .interactive else {
            NSApp.deactivate()
            NSApp.setActivationPolicy(.accessory)
            return
        }
        if settings.showDockIcon {
            NSApp.setActivationPolicy(.regular)
            if activate {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.deactivate()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Actions

    private func setMouseEnhancementEnabled(_ enabled: Bool) {
        settingsModel.update(actionName: L10n.string(.App.applicationToggleMouseEnhancement)) { $0.mouseEnhancement.isEnabled = enabled }
        Task { [weak self] in
            guard let self, await settingsModel.finishPendingChanges() else { return }
            refreshMenuBar()
        }
    }

    private func setWindowManagementEnabled(_ enabled: Bool) {
        settingsModel.update(actionName: L10n.string(.App.applicationToggleWindowManagement)) { $0.windowManagement.isEnabled = enabled }
        Task { [weak self] in
            guard let self, await settingsModel.finishPendingChanges() else { return }
            refreshMenuBar()
        }
    }

    private func setFinderContextMenuEnabled(_ enabled: Bool) {
        settingsModel.update(actionName: L10n.string(.App.applicationToggleFinderContextMenu)) {
            $0.finder.menuConfiguration.isEnabled = enabled
        }
        Task { [weak self] in
            guard let self, await settingsModel.finishPendingChanges() else { return }
            refreshMenuBar()
        }
    }

    @objc func requestAccessibilityPermission() {
        runtime.requestAccessibilityPermission()
    }

    @objc func openAccessibilitySettings() {
        runtime.openAccessibilitySettings()
    }

    @objc func openExtensionSettings() {
        FinderExtensionStatusService.showExtensionManagementInterface()
    }

    @objc func reloadSettings() {
        settingsModel.reload()
        systemEnhancementService.refresh()
        loginService.refreshLaunchAtLoginStatus()
        runtime.refreshRuntimeState(retryConnection: true)
        runtime.recorder.write(reason: "settings-reloaded")
        refreshMenuBar()
    }

    private func checkMenuBarState() {
        let state = menuBarController.state
        guard !state.statusCheck.isChecking else { return }
        state.statusCheck = .checking
        runtime.checkState { [weak self] result in
            guard let self else { return }
            refreshMenuBar()
            switch result {
            case .success:
                let windowEnabled = settings.windowManagement.isEnabled
                let mouseEnabled = settings.mouseEnhancement.isEnabled
                let finderEnabled = settings.finder.menuConfiguration.isEnabled
                let checks: [(String, FeatureHealth)] = [
                    (L10n.string(.App.applicationBackgroundPermission), runtime.permissions.backgroundHealth(required: windowEnabled || mouseEnabled || finderEnabled)),
                    (L10n.string(.Common.windows), state.windowHealth),
                    (L10n.string(.Common.mouse), state.mouseHealth),
                    (L10n.string(.App.applicationMenuBarInputMonitoring), runtime.permissions.menuInputHealth(required: windowEnabled)),
                    (L10n.string(.App.applicationFinderExtensionSwitch), runtime.permissions.finderHealth(required: finderEnabled))
                ].filter { $0.1.state != .disabled }
                let needsAttention = checks.contains { $0.1.state != .ready }
                var detail = checks.map { name, health in
                    "\(name)：\(health.title)\(health.state == .ready ? "" : "；" + health.detail)"
                }.joined(separator: "\n")
                if checks.isEmpty { detail = L10n.string(.App.applicationWindowsMouseFinderAllOff) }
                else if finderEnabled { detail += L10n.string(.App.applicationFinderConnectionHint) }
                state.statusCheck = .completed(detail: detail, needsAttention: needsAttention, at: Date())
            case let .failure(error):
                state.statusCheck = .failed(message: error.localizedDescription, at: Date())
            }
        }
    }

    @objc public func showMainWindow() {
        showMainWindow(section: nil)
    }

    @objc func showQuickFind() {
        presentSettings { $0.show(opensQuickFind: true) }
    }

    @objc func showOverview() {
        showMainWindow(section: .overview)
    }

    @objc func showFinderSection() {
        showMainWindow(section: .finder)
    }

    @objc func showWindowSection() {
        showMainWindow(section: .window)
    }

    @objc func showMouseSection() {
        showMainWindow(section: .mouse)
    }

    @objc func showWallpaperSection() {
        showMainWindow(section: .wallpaper)
    }

    private func showMainWindow(section: MainWindowSection?) {
        presentSettings { $0.show(section: section) }
    }

    private func captureSettingsWindowTarget(completion: (() -> Void)? = nil) {
        let captureID = settingsWindowTarget.begin()
        runtime.windowService.captureWindowTarget { [weak self] capture in
            guard let self, settingsWindowTarget.complete(capture, for: captureID) else { return }
            completion?()
        }
    }

    private func presentSettings(_ present: @escaping (MainWindowController) -> Void) {
        // 和快捷面板一样，完成窗口捕获后才激活设置；迟到的旧请求不能再次弹窗。
        captureSettingsWindowTarget { [weak self] in
            guard let self else { return }
            enterInteractivePresentation()
            present(mainWindowController)
        }
    }

    private func enterInteractivePresentation() {
        launchMode = .interactive
        applyActivationPolicy(activate: true)
    }

    @objc func showPreferences() {
        showMainWindow(section: .preferences)
    }

    @objc func showAbout() {
        enterInteractivePresentation()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: L10n.string(.App.applicationDescription)
            ),
        ])
    }

    @objc func checkForUpdates() {
        enterInteractivePresentation()
        mainWindowController.show(section: .preferences, preferenceTarget: .about)
        updateService.checkForUpdates()
    }

    @objc func undoSettings() {
        settingsModel.undo()
    }

    @objc func redoSettings() {
        settingsModel.redo()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoSettings):
            menuItem.title = settingsModel.undoMenuTitle
            return settingsModel.canUndo
        case #selector(redoSettings):
            menuItem.title = settingsModel.redoMenuTitle
            return settingsModel.canRedo
        default:
            return true
        }
    }

    private func performWindowAction(_ action: WindowLayoutAction) {
        runtime.windowService.perform(action, target: settingsWindowTarget.result)
    }

    public func shutdown() {
        settingsWindowTarget.reset()
        wallpaperModel.stop()
        finderDiagnostics.close()
        ArcKitLog.flush()
        runtime.stop()
        menuBarRefreshWorkItem?.cancel()
        menuBarController.stop()
    }

    /// 菜单退出、Command-Q 与系统正常终止共用此流程；关闭管理窗口不会走这里。
    public func prepareForTermination() async -> Bool {
        if uninstallCompleted { return true }
        guard let operation = try? settingsModel.operations.begin(.termination) else {
            showAlert(title: L10n.string(.App.applicationUnsavedSettings), message: L10n.string(.App.applicationWaitCurrentOperationFinish), style: .warning)
            return false
        }
        defer { settingsModel.operations.end(operation) }
        guard await settingsModel.drainPendingChanges(under: operation) else {
            showAlert(title: L10n.string(.App.applicationUnsavedSettings), message: L10n.string(.App.applicationWaitCurrentOperationFinish), style: .warning)
            return false
        }
        guard !isUninstalling else { return false }
        await backgroundModel.finishPendingChanges()
        await wallpaperModel.finishPendingChanges()
        shutdown()
        do {
            try await runtime.host.unregisterForQuit()
            return true
        } catch {
            // 停止失败不能伪装成完整退出；恢复可操作界面，允许用户重试。
            runtime.start()
            wallpaperModel.start()
            showAlert(title: L10n.string(.App.applicationQuitIncomplete), message: error.localizedDescription, style: .warning)
            return false
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func uninstallArcKit(deleteData: Bool) {
        guard !isUninstalling, !settingsModel.isOperationRunning else { return }
        if deleteData, NSScreen.screens.contains(where: { screen in
            NSWorkspace.shared.desktopImageURL(for: screen)?.path.hasPrefix(settingsModel.store.directoryURL.path + "/") == true
        }) {
            showAlert(title: L10n.string(.App.applicationDesktopUsingArcKitAssets), message: L10n.string(.App.applicationSwitchSystemWallpaperDeleting), style: .warning)
            return
        }
        // 确认卸载后立即取得同一租约，直到卸载结束或失败恢复后才释放。
        guard let operation = try? settingsModel.operations.begin(.uninstall) else { return }
        isUninstalling = true
        shutdown()
        Task { [weak self] in
            guard let self else { return }
            let registrationSnapshot: RuntimeServiceRegistrationSnapshot
            do {
                guard await settingsModel.drainPendingChanges(under: operation) else { throw CocoaError(.fileWriteUnknown) }
                await wallpaperModel.finishPendingChanges()
                await backgroundModel.finishPendingChanges()
                registrationSnapshot = try await runtime.host.unregisterForUninstall()
            } catch {
                isUninstalling = false
                settingsModel.operations.end(operation)
                runtime.start()
                wallpaperModel.start()
                showAlert(title: L10n.string(.App.applicationUninstallFailed), message: error.localizedDescription, style: .warning)
                return
            }
            uninstallService.uninstall(onFailure: { [weak self] in
                guard let self else { return }
                defer { self.isUninstalling = false; self.settingsModel.operations.end(operation); self.runtime.start(); self.wallpaperModel.start() }
                do {
                    try self.runtime.host.restoreAfterFailedUninstall(registrationSnapshot)
                } catch {
                    self.showAlert(title: L10n.string(.App.applicationHostRestoreFailed), message: error.localizedDescription, style: .critical)
                }
            }) { [weak self] _ in
                guard let self else { return }
                Task {
                    if deleteData {
                        let database = settingsModel.store.database
                        do {
                            try await Task.detached {
                                try database.close()
                                ArcKitLog.stopFileLogging()
                                try FileManager.default.trashItem(at: database.paths.root, resultingItemURL: nil)
                            }.value
                        } catch { showAlert(title: L10n.string(.App.applicationAppUninstalledDataPreserved), message: error.localizedDescription, style: .warning) }
                    }
                    uninstallCompleted = true; isUninstalling = false
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    @objc func showFinderExtensionDiagnostics() {
        let required = settings.windowManagement.isEnabled || settings.mouseEnhancement.isEnabled
        let status = runtime.permissions.accessibilityHealth(required: required)
        let accessibilityStatus = "Runtime Host：\(status.title)；\(status.detail)"
        finderDiagnostics.show(snapshotStore: runtime.snapshotStore, accessibilityStatus: accessibilityStatus)
    }

    @objc func repairFinderExtension() { performFinderRepair(completion: {}) }

    private func performFinderRepair(completion: @escaping () -> Void) {
        guard !isRepairingFinder else { return }
        ArcKitLog.append("repair finder extension requested")
        guard let currentSettings = runtime.committedSettings?.finder else {
            showAlert(title: L10n.string(.App.applicationFinderSettingsNotReady), message: L10n.string(.App.applicationRestoreSettingsAccessRepairingFinder), style: .warning)
            return
        }
        isRepairingFinder = true
        runtime.host.retryConnection()
        let snapshotStore = runtime.snapshotStore
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                FinderExtensionStatusService.repairFinderExtension(
                    settings: currentSettings,
                    snapshotStore: snapshotStore
                )
            }.value
            guard let self else { return }
            isRepairingFinder = false
            mainWindowController.refreshFinderAfterRepair()
            completion()
            showAlert(title: report.title, message: report.message, style: report.succeeded ? .informational : .warning)
            if !FinderExtensionStatusService.isExtensionEnabledByUser() {
                FinderExtensionStatusService.showExtensionManagementInterface()
            }
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: L10n.string(.DataManagement.transferGot))
        alert.runModal()
    }

}
