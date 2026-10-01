import ArcKitPlatform
import SwiftUI

enum OverviewWorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case status, permissions, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .status: L10n.string(.Overview.pageFeatureStatus)
        case .permissions: L10n.string(.Overview.pagePermissions)
        case .diagnostics: L10n.string(.DataManagement.storageDiagnostics)
        }
    }
}

struct OverviewSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var mouseService: MouseScrollEnhancementService
    @ObservedObject var healthModel: AppRuntimeHealthModel
    @ObservedObject var permissions: ApplicationPermissions
    let finderHealth: FeatureHealth
    let windowHealth: FeatureHealth
    let mouseHealth: FeatureHealth
    let actions: RuntimeHealthActions
    let refresh: () -> Void
    let openSection: (MainWindowSection) -> Void
    @Binding var selectedTab: OverviewWorkspaceTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L10n.string(.Common.home), selection: $selectedTab) {
                    ForEach(OverviewWorkspaceTab.allCases) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(healthModel.isRefreshing ? L10n.string(.Overview.pageChecking) : L10n.string(.Settings.generalCheckAgain), action: refresh)
                    .disabled(healthModel.isPreview || healthModel.isRefreshing)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Form {
                switch selectedTab {
                case .status:
                    Section {
                        featureRow(.finder, health: finderHealth, enabled: model.settings.finder.menuConfiguration.isEnabled)
                        featureRow(.window, health: windowHealth, enabled: model.settings.windowManagement.isEnabled)
                        featureRow(.mouse, health: mouseHealth, enabled: model.settings.mouseEnhancement.isEnabled)
                    }
                case .permissions:
                    permissionSections
                case .diagnostics:
                    FinderDiagnosticsView(healthModel: healthModel, health: finderHealth, actions: actions, refresh: refresh)
                    if healthModel.isPreview {
                        Section(L10n.string(.MouseSettings.pageScrollDiagnostics)) { Text(L10n.string(.Overview.pageInputSamplesUnavailable)).foregroundStyle(.secondary) }
                    } else if mouseHealth.permission == .unknown || mouseHealth.state == .disabled {
                        Section(L10n.string(.MouseSettings.pageScrollDiagnostics)) { Text(mouseHealth.detail).foregroundStyle(.secondary) }
                    } else {
                        MouseDiagnosticsView(mouseService: mouseService)
                    }
                }
                if healthModel.isPreview {
                    Text(L10n.string(.Overview.pageDebugScope))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .appBackgroundSurface()
            .id(selectedTab)
        }
    }

    private func featureRow(_ section: MainWindowSection, health: FeatureHealth, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ArcIcon(section.icon, size: 16)
                Text(section.title)
                Text(enabled ? L10n.string(.Common.enabled) : L10n.string(.Common.off)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(health.title).foregroundStyle(health.color)
                Button(L10n.string(.Overview.pageSettings)) { openSection(section) }.buttonStyle(.borderless)
            }
            if health.state != .disabled {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(health.detail).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if health.action != .settings {
                        FeatureHealthActionButton(health: health, actions: actions, refresh: refresh)
                    }
                }
            }
            if let checkedAt = health.checkedAt {
                Text(L10n.string(.Overview.pageChecked(String(describing: L10n.time(checkedAt)))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var permissionSections: some View {
        let settings = model.committedSettings
        let inputRequired = settings?.windowManagement.isEnabled == true || settings?.mouseEnhancement.isEnabled == true
        let finderRequired = settings?.finder.menuConfiguration.isEnabled == true
        return Group {
            Section(L10n.string(.Overview.pageSystemPermissions)) {
                permissionRow(L10n.string(.Overview.pageAccessibility), health: permissions.accessibilityHealth(required: inputRequired))
                permissionRow(L10n.string(.App.applicationMenuBarInputMonitoring), health: permissions.menuInputHealth(required: settings?.showMenuBarIcon == true && settings?.windowManagement.isEnabled == true))
                permissionRow(L10n.string(.Overview.pageFinderExtension), health: permissions.finderHealth(required: finderRequired))
                permissionRow(L10n.string(.Overview.pageBackgroundExecution), health: permissions.backgroundHealth(required: inputRequired || finderRequired))
            }
            Section(L10n.string(.Overview.pageRequestedPerAction)) {
                HStack {
                    Text(L10n.string(.Overview.pageTerminalAutomation))
                    Spacer()
                    Text(L10n.string(.Overview.pageRequestedPerTargetApp)).foregroundStyle(.secondary)
                    if !healthModel.isPreview {
                        Button(L10n.string(.Overview.pageManageAccess), action: actions.openAutomationSettings).buttonStyle(.borderless)
                    }
                }
                LabeledContent(L10n.string(.Overview.pageFilesFolders), value: L10n.string(.Overview.pageDeterminedMacosAccessingProtectedLocations))
                Text(L10n.string(.Overview.pageCreatingTerminalTabsWindowsRunning))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ title: String, health: FeatureHealth) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(health.title).foregroundStyle(health.color)
                FeatureHealthActionButton(health: health, actions: actions, refresh: refresh)
            }
            Text(health.detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
