import ArcKitPlatform
import ArcKitFinder
import AppKit
import SwiftUI

// MARK: - Finder workspace tab

enum FinderWorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case menu, templates, directories, applications, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: L10n.string(.FinderSettings.pageMenuItems)
        case .templates: L10n.string(.FinderSettings.pageNewFile)
        case .directories: L10n.string(.FinderSettings.pageFavoriteFolders)
        case .applications: L10n.string(.FinderSettings.pageFavoriteApps)
        case .settings: L10n.string(.FinderSettings.pageScope)
        }
    }

}

private enum FinderBulkResetAction: String, Identifiable {
    case menuLayout
    case templates
    case directories
    case applications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuLayout: L10n.string(.FinderSettings.pageRestoreRecommendedMenuLayout)
        case .templates: L10n.string(.FinderSettings.pageRestoreDefaultFileTemplates)
        case .directories: L10n.string(.FinderSettings.pageClearAllFavoriteFolders)
        case .applications: L10n.string(.FinderSettings.pageRestoreFavoritesConfirmation)
        }
    }

    var confirmTitle: String {
        switch self {
        case .menuLayout: L10n.string(.FinderSettings.pageRestoreRecommendedLayout)
        case .templates: L10n.string(.FinderSettings.templatesRestoreDefaultTemplates)
        case .directories: L10n.string(.FinderSettings.pageClearAllFolders)
        case .applications: L10n.string(.FinderSettings.favoritesRestoreDefaultApps)
        }
    }

    var message: String {
        switch self {
        case .menuLayout:
            L10n.string(.FinderSettings.pageRestoresFinderMenuOrderOptional)
        case .templates:
            L10n.string(.FinderSettings.pageRemovesCustomTemplateEntriesRestoresAll)
        case .directories:
            L10n.string(.FinderSettings.pageClearsFavoriteFoldersFinderMenu)
        case .applications:
            L10n.string(.FinderSettings.pageRemovesManuallyAddedFavoriteAppsRestores)
        }
    }
}

// MARK: - Finder Section

struct FinderSection: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let templateLibrary: NewFileTemplateLibrary
    @Binding var selectedTab: FinderWorkspaceTab
    @State private var showsPreview = false
    @State private var pendingBulkReset: FinderBulkResetAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                finderControl
                tabPicker
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Form {
                Section {
                    HStack(spacing: 12) {
                        Text(L10n.string(.FinderSettings.pageMenuPreview)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.string(.FinderSettings.pagePreview)) { showsPreview = true }
                            .popover(isPresented: $showsPreview) {
                                FinderContextMenuPreview(settings: model.settings, isDraft: model.hasUncommittedChanges)
                                    .frame(width: 420, height: 480)
                            }
                    }
                }
                switch selectedTab {
                case .menu:
                    FinderMenuEditor(model: model, configure: { selectedTab = $0 }, requestReset: { pendingBulkReset = .menuLayout })
                case .templates:
                    FinderTemplatesEditor(model: model, templateLibrary: templateLibrary, requestReset: { pendingBulkReset = .templates })
                case .directories:
                    FinderDirectoriesEditor(model: model, requestReset: { pendingBulkReset = .directories })
                case .applications:
                    FinderApplicationsEditor(model: model, requestReset: { pendingBulkReset = .applications })
                case .settings:
                    FinderPreferencesEditor(model: model)
                }
            }
            .formStyle(.grouped)
            .appBackgroundSurface()
            .id(selectedTab)
        }
        .confirmationDialog(
            pendingBulkReset?.title ?? L10n.string(.FinderSettings.pageConfirmBulkRestore),
            isPresented: Binding(
                get: { pendingBulkReset != nil },
                set: { if !$0 { pendingBulkReset = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBulkReset
        ) { action in
            Button(action.confirmTitle, role: .destructive) {
                performBulkReset(action)
            }
            Button(L10n.string(.Common.cancel), role: .cancel) {
                pendingBulkReset = nil
            }
        } message: { action in
            Text(action.message)
        }
    }

    private var tabPicker: some View {
        Picker(L10n.string(.FinderSettings.pageFinderSettings), selection: $selectedTab) {
            ForEach(FinderWorkspaceTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var finderControl: some View {
        Toggle(model.settings.menuConfiguration.isEnabled ? L10n.string(.Common.enabled) : L10n.string(.Common.disabled), isOn: Binding(
            get: { model.settings.menuConfiguration.isEnabled },
            set: { value in
                model.update(actionName: value ? L10n.string(.FinderSettings.pageEnableMenuAction) : L10n.string(.FinderSettings.pageTurnOffFinderContextMenu)) {
                    $0.menuConfiguration.isEnabled = value
                }
            }
        ))
        .toggleStyle(.switch)
        .fixedSize()
        .accessibilityLabel(L10n.string(.FinderSettings.pageTurnFinderContextMenu))
        .help(L10n.string(.FinderSettings.pageFinderContextMenuMasterSwitch))
    }

    private func resetTemplates() {
        model.update(actionName: L10n.string(.FinderSettings.pageResetFileTemplates)) {
            $0.menuConfiguration.fileTemplates = ConfigurableNewFileTemplate.defaults
        }
    }

    private func resetDirs() {
        model.update(actionName: L10n.string(.FinderSettings.pageClearFavoriteFolders)) { $0.menuConfiguration.favoriteDirectories = [] }
    }

    private func resetApps() {
        model.update(actionName: L10n.string(.FinderSettings.pageRestoreDefaultFavoriteApps)) {
            $0.menuConfiguration.favoriteApplications = FavoriteApplication.defaults
        }
    }

    private func resetRecommendedModules() {
        model.update(actionName: L10n.string(.FinderSettings.pageRestoreRecommendedFinderLayout)) {
            $0.menuConfiguration.modules = FinderMenuConfiguration.defaultModules
        }
    }

    private func performBulkReset(_ action: FinderBulkResetAction) {
        pendingBulkReset = nil
        switch action {
        case .menuLayout:
            resetRecommendedModules()
        case .templates:
            resetTemplates()
        case .directories:
            resetDirs()
        case .applications:
            resetApps()
        }
    }
}
