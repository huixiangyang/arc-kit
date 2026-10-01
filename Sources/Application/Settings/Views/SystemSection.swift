import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import SwiftUI

/// 系统设置只负责分组；数据操作统一归数据管理页面。
struct SystemSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var dataModel: DataManagementModel
    @ObservedObject var loginService: LaunchAtLoginService
    @ObservedObject var backgroundModel: AppBackgroundModel
    @ObservedObject var systemService: SystemEnhancementService
    @ObservedObject var supportDiagnosticsService: SupportDiagnosticsService
    @ObservedObject var uninstallService: ArcKitUninstallService
    @ObservedObject var updateService: ArcKitUpdateService
    @Binding var selectedTab: PreferencesWorkspaceTarget
    let openWallpaperLibrary: () -> Void
    let actions: GeneralSettingsActions
    let dataActions: DataManagementActions

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string(.Common.settings), selection: $selectedTab) {
                ForEach(PreferencesWorkspaceTarget.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Form {
                switch selectedTab {
                case .application:
                    applicationSettings
                    systemIntegrationSettings
                case .background: AppBackgroundEditor(model: backgroundModel, openLibrary: openWallpaperLibrary)
                case .dataManagement:
                    DataManagementView(model: dataModel, settingsModel: model, supportDiagnosticsService: supportDiagnosticsService,
                                       uninstallService: uninstallService, actions: dataActions)
                case .about: aboutSettings
                }
            }
            .formStyle(.grouped)
            .appBackgroundSurface()
            .id(selectedTab)
        }
        .onAppear { refreshExternalState() }
        .onChange(of: selectedTab) { _ in refreshExternalState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExternalState()
        }
    }

    private var applicationSettings: some View {
        Section(L10n.string(.Settings.generalApplication)) {
            Toggle(L10n.string(.Settings.generalShowMenuBar), isOn: Binding(
                get: { model.settings.showMenuBarIcon },
                set: { value in model.update(actionName: L10n.string(.Settings.generalToggleMenuBarVisibility)) { $0.showMenuBarIcon = value } }
            ))
            .help(L10n.string(.Settings.generalReopenArcKit))
            Toggle(L10n.string(.Settings.generalShowDock), isOn: Binding(
                get: { model.settings.showDockIcon },
                set: { v in model.update(actionName: L10n.string(.Settings.generalToggleDockVisibility)) { $0.showDockIcon = v } }
            ))
            .help(L10n.string(.Settings.generalReopenArcKit))
            Toggle(L10n.string(.Settings.generalLaunchArcKitLogin), isOn: Binding(
                get: { model.settings.launchAtLoginEnabled },
                set: { v in model.update(actionName: L10n.string(.Settings.generalToggleLaunchLogin)) { $0.launchAtLoginEnabled = v } }
            ))
            if let error = loginService.lastLaunchAtLoginError {
                launchAtLoginFailure(error)
            } else if loginService.launchAtLoginState == .requiresApproval {
                HStack {
                    Text(L10n.string(.Settings.generalWaitingPermissionLaunchLogin)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string(.Settings.generalLoginItemsSettings), action: actions.openLoginItemsSettings).buttonStyle(.borderless)
                }
            } else if loginService.launchAtLoginState == .unknown {
                Text(L10n.string(.Settings.generalLoginStatusUnconfirmed))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker(L10n.string(.Settings.languageTitle), selection: Binding(
                get: { model.settings.language },
                set: { value in model.update(actionName: L10n.string(.Settings.languageChange)) { $0.language = value } }
            )) {
                ForEach(ArcKitLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .help(L10n.string(.Settings.generalUpdatesAppFinderMenus))
            Picker(L10n.string(.Common.appearance), selection: Binding(
                get: { model.settings.appearance },
                set: { value in model.update(actionName: L10n.string(.Settings.generalChangeAppearance)) { $0.appearance = value } }
            )) {
                ForEach(ArcAppearance.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Toggle(L10n.string(.Settings.generalReduceMotion), isOn: Binding(
                get: { model.settings.reduceMotionEnabled },
                set: { v in model.update(actionName: L10n.string(.Settings.generalToggleMotionEffects)) { $0.reduceMotionEnabled = v } }
            ))

        }
    }

    private var systemIntegrationSettings: some View {
        Section(L10n.string(.AppBackground.backgroundStorageSystem)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(.Settings.generalHiddenFilesFinder)).font(.subheadline.weight(.medium))
                    Text(L10n.string(.Settings.generalCurrently(String(describing: hiddenFilesText)))).font(.caption).foregroundStyle(ArcPalette.mutedText)
                }
                Spacer()
                ArcToolbarButton(
                    title: systemService.isTogglingHiddenFiles ? L10n.string(.Settings.generalApplying) : hiddenFilesActionTitle,
                    symbol: .arcRefresh,
                    action: performHiddenFilesAction
                )
                .disabled(systemService.isTogglingHiddenFiles)
            }
            if let error = systemService.hiddenFilesError {
                systemIntegrationFeedback(error, dismiss: systemService.clearHiddenFilesError)
            }


            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(.Settings.generalScreenshotLocation)).font(.subheadline.weight(.medium))
                    Text(systemService.screenshotLocationDescription)
                        .font(.caption)
                        .foregroundStyle(ArcPalette.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(systemService.screenshotLocationPath ?? L10n.string(.Settings.systemDesktopSystemDefault))
                }
                Spacer()
                ArcToolbarButton(title: L10n.string(.Settings.generalChooseFolder), symbol: .arcFinder, action: actions.chooseScreenshotLocation)
                ArcToolbarButton(title: L10n.string(.Common.restoreDefaults), symbol: .arcRefresh, action: actions.resetScreenshotLocation)
                    .disabled(systemService.isScreenshotLocationDefault)
            }
            if let error = systemService.screenshotLocationError {
                systemIntegrationFeedback(error, dismiss: systemService.clearScreenshotLocationError)
            }
        }
    }

    private var aboutSettings: some View {
        Section(L10n.string(.App.menuAboutArcKit)) {
            AboutSection(updateService: updateService)
        }
    }

    /// 切换分组或返回应用时刷新外部状态；快速查找直接选择对应 Tab。
    private func refreshExternalState() {
        systemService.refresh()
        loginService.refreshLaunchAtLoginStatus()
    }

    private var hiddenFilesText: String {
        switch systemService.hiddenFilesState {
        case .enabled:  L10n.string(.Settings.generalShown)
        case .disabled: L10n.string(.Settings.generalHidden)
        case .unknown:  L10n.string(.Common.unknown)
        }
    }

    private var hiddenFilesActionTitle: String {
        switch systemService.hiddenFilesState {
        case .enabled:  L10n.string(.Settings.generalStopShowing)
        case .disabled: L10n.string(.Settings.generalShowHiddenFiles)
        case .unknown:  L10n.string(.Settings.generalCheckAgain)
        }
    }

    private func performHiddenFilesAction() {
        if systemService.hiddenFilesState == .unknown {
            systemService.refreshHiddenFilesState()
        } else {
            actions.toggleHiddenFiles()
        }
    }

    private func systemIntegrationFeedback(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ArcIcon(.triangleAlert, size: 13)
                .foregroundStyle(ArcPalette.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(ArcPalette.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.string(.Common.close), action: dismiss)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(ArcPalette.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ArcPalette.orange.opacity(0.2), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private func launchAtLoginFailure(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ArcIcon(.triangleAlert, size: 13)
                .foregroundStyle(ArcPalette.red)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(.Settings.generalLoginEnableUnconfirmed))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcPalette.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(ArcPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.string(.Settings.generalCurrentStatus(String(describing: loginService.launchAtLoginState.displayName))))
                    .font(.caption2)
                    .foregroundStyle(ArcPalette.mutedText)
            }
            Spacer(minLength: 12)
            Button(L10n.string(.Common.retry), action: actions.retryLaunchAtLoginChange)
                .buttonStyle(.borderedProminent)
            Button(L10n.string(.Common.settings), action: actions.openLoginItemsSettings)
                .buttonStyle(.bordered)
        }
        .padding(10)
        .background(ArcPalette.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ArcPalette.red.opacity(0.2), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

}
