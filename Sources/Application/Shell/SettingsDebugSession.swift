#if DEBUG
import ArcKitPersistence
import ArcKitPlatform
import AppKit
import ArcKitFinder
import Foundation
import Combine

/// 管理页调试复用真实窗口和配置绑定，独立保存草稿，不启动产品生命周期及后台。
@MainActor
public final class SettingsDebugSession: NSObject, NSApplicationDelegate {
    private var languageObservation: AnyCancellable?
    private let model: SettingsModel
    private let dataModel: DataManagementModel
    private let runtime: ApplicationRuntime
    private let wallpaperModel: WallpaperModel
    private let backgroundModel: AppBackgroundModel
    private let healthModel = AppRuntimeHealthModel(isPreview: true)
    private lazy var window = MainWindowController(
        windowTitle: "Arc Kit · Debug",
        refreshFinder: { [unowned self] in healthModel.refreshAfterRepair() },
        setWindowVisible: { [unowned self] in backgroundModel.setWindowVisible($0) }
    ) { [unowned self] navigation in
        ApplicationWorkspace(
            model: model,
            dataModel: dataModel,
            loginService: LaunchAtLoginService(),
            systemService: SystemEnhancementService(),
            wallpaperModel: wallpaperModel,
            backgroundModel: backgroundModel,
            mouseService: runtime.mouseService,
            windowService: runtime.windowService,
            hotKeyService: runtime.hotKeyService,
            supportDiagnosticsService: SupportDiagnosticsService(),
            uninstallService: ArcKitUninstallService(),
            updateService: ArcKitUpdateService(),
            healthModel: healthModel,
            permissions: runtime.permissions,
            navigation: navigation,
            actions: actions
        )
    }

    private init(paths: ArcKitStoragePaths) {
        let database = ApplicationStorage.database
        wallpaperModel = WallpaperModel(isPreview: true, library: WallpaperLibrary(database: database))
        backgroundModel = AppBackgroundModel(store: AppBackgroundStore(database: database))
        model = SettingsModel(store: SettingsRepository(database: database),
            templateLibrary: NewFileTemplateLibrary(baseDirectory: paths.templates))
        dataModel = DataManagementModel(settingsModel: model,
            backupService: SettingsBackupService(automaticBackupURL: paths.backups.appendingPathComponent("LastSettingsBackup.json"), managedTemplateDirectory: paths.templates))
        // 只取得未连接的展示服务，禁止调用 start，避免抢占安装版的 Host 会话。
        runtime = ApplicationRuntime(settingsModel: model)
        super.init()
        languageObservation = model.$committedSettings.compactMap { $0?.language }.removeDuplicates().sink { [weak self] language in
            L10n.configure(language)
            self?.model.objectWillChange.send()
            NSApplication.shared.mainMenu?.items.first?.submenu?.items.first?.title = L10n.string(.App.debugExitDebug)
        }
        dataModel.beforeStorageOperation = { [weak self] restoring in
            guard let self else { return }
            await wallpaperModel.finishPendingChanges()
            await backgroundModel.finishPendingChanges()
            guard !wallpaperModel.channels.busy else { throw CocoaError(.userCancelled) }
            if case .failed(let message) = backgroundModel.persistenceState { throw ArcKitDatabaseError.message(message) }
            if restoring { wallpaperModel.stop() }
        }
        dataModel.afterStorageOperation = { [weak self] restoring in
            guard let self, restoring else { return }
            // 恢复后重新加载调试模型，仍不启动 Runtime 或安装版后台。
            backgroundModel.reload()
            wallpaperModel.start()
        }
    }

    public static func run() {
        let paths = ArcKitStoragePaths.current
        let session = SettingsDebugSession(paths: paths)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = session
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.string(.App.debugExitDebug), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        application.mainMenu = menu
        application.finishLaunching()
        session.wallpaperModel.start()
        session.window.show()
        print("UI_DEBUG_READY pid=\(ProcessInfo.processInfo.processIdentifier) settings=\(paths.root.path)")
        withExtendedLifetime(session) { application.run() }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let operation = try? model.operations.begin(.termination) else { return .terminateCancel }
        Task {
            defer { model.operations.end(operation) }
            await wallpaperModel.finishPendingChanges()
            await backgroundModel.finishPendingChanges()
            let saved = await model.drainPendingChanges(under: operation)
            if case .failed = backgroundModel.persistenceState {
                sender.reply(toApplicationShouldTerminate: false)
            } else {
                sender.reply(toApplicationShouldTerminate: saved)
            }
        }
        return .terminateLater
    }
    public func applicationWillTerminate(_ notification: Notification) { wallpaperModel.stop(); ArcKitLog.flush() }

    private var actions: ApplicationActions {
        let requiresInstalledApp: () -> Void = {
            let alert = NSAlert()
            alert.messageText = L10n.string(.App.debugInstalledAppRequired)
            alert.informativeText = L10n.string(.App.debugWindowPreviewsSettingsPagesSaves)
            alert.runModal()
        }
        return ApplicationActions(
            health: RuntimeHealthActions(
                requestAccessibilityPermission: requiresInstalledApp,
                openAccessibilitySettings: requiresInstalledApp,
                requestMenuInputPermission: requiresInstalledApp,
                openInputMonitoringSettings: requiresInstalledApp,
                openAutomationSettings: requiresInstalledApp,
                openExtensionSettings: requiresInstalledApp,
                showFinderExtensionDiagnostics: requiresInstalledApp,
                repairFinderExtension: { _ in requiresInstalledApp() },
                openLoginItemsSettings: requiresInstalledApp,
                refreshRuntimeState: requiresInstalledApp
            ),
            general: GeneralSettingsActions(
                toggleHiddenFiles: requiresInstalledApp,
                chooseScreenshotLocation: requiresInstalledApp,
                resetScreenshotLocation: requiresInstalledApp,
                openLoginItemsSettings: requiresInstalledApp,
                retryLaunchAtLoginChange: requiresInstalledApp
            ),
            data: DataManagementActions(
                exportBackup: { _ in requiresInstalledApp() },
                revealExportedBackup: requiresInstalledApp,
                restoreBackup: requiresInstalledApp,
                exportSupportDiagnostics: requiresInstalledApp,
                uninstallArcKit: { _ in requiresInstalledApp() }
            ),
            window: WindowCommandActions(
                prepareQuickFind: {},
                performWindowAction: { _ in requiresInstalledApp() }
            )
        )
    }
}
#endif
