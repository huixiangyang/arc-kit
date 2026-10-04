import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import SwiftUI

struct ApplicationWorkspace: View {
    @ObservedObject private var model: SettingsModel
    @ObservedObject private var dataModel: DataManagementModel
    @ObservedObject private var loginService: LaunchAtLoginService
    @ObservedObject private var systemService: SystemEnhancementService
    @ObservedObject private var wallpaperModel: WallpaperModel
    @ObservedObject private var backgroundModel: AppBackgroundModel
    @ObservedObject private var mouseService: MouseScrollEnhancementService
    @ObservedObject private var windowService: WindowManagementService
    @ObservedObject private var hotKeyService: GlobalHotKeyService
    @ObservedObject private var supportDiagnosticsService: SupportDiagnosticsService
    @ObservedObject private var uninstallService: ArcKitUninstallService
    @ObservedObject private var updateService: ArcKitUpdateService
    @ObservedObject private var permissions: ApplicationPermissions
    @ObservedObject private var healthModel: AppRuntimeHealthModel
    @ObservedObject private var navigation: MainWindowNavigationModel
    private let actions: ApplicationActions

    // 标签属于窗口导航状态，切换侧栏后仍回到上次编辑的分组。
    @State private var finderTab: FinderWorkspaceTab = .menu
    @State private var mouseTab: MouseWorkspaceTab = .scrolling
    @State private var overviewTab: OverviewWorkspaceTab = .status
    @State private var wallpaperTab: WallpaperWorkspaceTab = .library
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    init(
        model: SettingsModel,
        dataModel: DataManagementModel,
        loginService: LaunchAtLoginService,
        systemService: SystemEnhancementService,
        wallpaperModel: WallpaperModel,
        backgroundModel: AppBackgroundModel,
        mouseService: MouseScrollEnhancementService,
        windowService: WindowManagementService,
        hotKeyService: GlobalHotKeyService,
        supportDiagnosticsService: SupportDiagnosticsService,
        uninstallService: ArcKitUninstallService,
        updateService: ArcKitUpdateService,
        healthModel: AppRuntimeHealthModel,
        permissions: ApplicationPermissions,
        navigation: MainWindowNavigationModel,
        actions: ApplicationActions
    ) {
        self.model = model
        self.dataModel = dataModel
        self.loginService = loginService
        self.systemService = systemService
        self.wallpaperModel = wallpaperModel
        self.backgroundModel = backgroundModel
        self.mouseService = mouseService
        self.windowService = windowService
        self.hotKeyService = hotKeyService
        self.supportDiagnosticsService = supportDiagnosticsService
        self.uninstallService = uninstallService
        self.updateService = updateService
        self.healthModel = healthModel
        self.permissions = permissions
        self.navigation = navigation
        self.actions = actions
    }

    var body: some View {
        MainWindowView(model: model, backgroundModel: backgroundModel, navigation: navigation,
            workspace: workspace, prepareQuickFind: actions.window.prepareQuickFind,
            executeQuickCommand: executeQuickCommand)
        .onAppear {
            healthModel.setFinderEnabled(model.committedSettings?.finder.menuConfiguration.isEnabled == true)
            healthModel.refresh()
            permissions.refreshSystem()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            healthModel.refresh()
            permissions.refreshSystem()
        }
        .onChange(of: model.committedSettings?.finder.menuConfiguration.isEnabled) { enabled in
            healthModel.setFinderEnabled(enabled == true)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch navigation.selection {
        case .overview:
            Group {
                OverviewSection(
                    model: model,
                    mouseService: mouseService,
                    healthModel: healthModel,
                    permissions: permissions,
                    finderHealth: finderHealth,
                    windowHealth: windowHealth,
                    mouseHealth: mouseHealth,
                    actions: actions.health,
                    refresh: refreshHealth,
                    openSection: { navigate(to: $0) },
                    selectedTab: $overviewTab
                )
            }
        case .finder:
            Group {
                FinderSection(model: model.finderEditor, templateLibrary: model.templateLibrary, selectedTab: $finderTab)
            }
        case .mouse:
            Group {
                MouseSection(model: model.mouseEditor, mouseService: mouseService, applicationCandidate: {
                    windowService.configurableApplicationCandidate().map {
                        MouseApplicationCandidate(displayName: $0.displayName, bundleIdentifier: $0.bundleIdentifier)
                    }
                }, health: mouseHealth, selectedTab: $mouseTab)
            }
        case .window:
            Group {
                WindowSection(
                    model: model.windowEditor,
                    windowService: windowService,
                    hotKeyService: hotKeyService,
                    health: windowHealth,
                    selectedTab: $navigation.windowTarget
                )
            }
        case .wallpaper:
            WallpaperSection(model: wallpaperModel,
                backgroundAction: WallpaperBackgroundIntegration.action(for: backgroundModel),
                backgroundFeedback: AppBackgroundFeedback(model: backgroundModel), selectedTab: $wallpaperTab)
        case .preferences:
            Group {
                SystemSection(
                    model: model,
                    dataModel: dataModel,
                    loginService: loginService,
                    backgroundModel: backgroundModel,
                    systemService: systemService,
                    supportDiagnosticsService: supportDiagnosticsService,
                    uninstallService: uninstallService,
                    updateService: updateService,
                    selectedTab: $navigation.preferencesTarget,
                    openWallpaperLibrary: { wallpaperTab = .library; navigate(to: .wallpaper) },
                    actions: actions.general,
                    dataActions: actions.data
                )
            }
        }
    }

    private var finderHealth: FeatureHealth {
        guard let settings = model.committedSettings else { return unloadedSettingsHealth }
        return FeatureHealthAssessment.finder(enabled: settings.finder.menuConfiguration.isEnabled,
            health: healthModel.finderHealth, preview: healthModel.isPreview,
            refreshing: healthModel.isRefreshing)
    }

    private var windowHealth: FeatureHealth {
        guard let settings = model.committedSettings else { return unloadedSettingsHealth }
        let service = FeatureHealthAssessment.window(settings: settings.windowManagement,
            snapshot: windowService.runtimeSnapshot, receivedAt: windowService.lastResponseAt,
            preview: healthModel.isPreview)
        return permissions.windowHealth(service, required: settings.windowManagement.isEnabled, menuBarVisible: settings.showMenuBarIcon)
    }

    private var mouseHealth: FeatureHealth {
        if model.committedSettings?.mouseEnhancement.isEnabled == true, let blocked = permissions.backgroundBlocker() { return blocked }
        guard let settings = model.committedSettings else { return unloadedSettingsHealth }
        return FeatureHealthAssessment.mouse(settings: settings.mouseEnhancement,
            snapshot: mouseService.runtimeSnapshot, receivedAt: mouseService.lastResponseAt,
            preview: healthModel.isPreview)
    }

    // 运行状态只评估已提交配置；编辑草稿的 pending/failed 由保存回执单独呈现。
    private var unloadedSettingsHealth: FeatureHealth {
        .init(state: .unknown, title: L10n.string(.App.windowSettingsNotLoaded), detail: L10n.string(.App.windowSettingsUnavailable))
    }

    private func refreshHealth() {
        permissions.refreshSystem()
        guard !healthModel.isPreview else { return }
        actions.health.refreshRuntimeState()
        healthModel.refresh(force: true)
    }

    private func navigate(to section: MainWindowSection) {
        navigation.navigate(to: section, reduceMotion: shouldReduceMotion)
    }

    private func executeQuickCommand(_ command: ArcKitQuickCommand) {
        switch command.action {
        case let .section(section):
            navigate(to: section)
        case let .overview(tab):
            overviewTab = tab
            navigate(to: .overview)
        case let .finder(tab):
            finderTab = tab
            navigate(to: .finder)
        case let .wallpaper(tab):
            wallpaperTab = tab
            navigate(to: .wallpaper)
        case let .preferences(target):
            navigation.requestPreferences(target)
            navigate(to: .preferences)
        case let .window(action):
            actions.window.performWindowAction(action)
        case .windowScenes:
            navigation.windowTarget = .scenes
            navigate(to: .window)
        case let .windowScene(id):
            actions.window.performScene(id)
        }
    }

    /// 系统辅助功能与 Arc Kit 独立偏好任一开启，都必须关闭非必要动画。
    private var shouldReduceMotion: Bool {
        systemReduceMotion || model.settings.reduceMotionEnabled
    }

}
