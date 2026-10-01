import ArcKitPlatform
import ArcKitFinder
import SwiftUI

/// 列表直接使用配置顺序；每行完成启用、资源设置和排序。
struct FinderMenuEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let configure: (FinderWorkspaceTab) -> Void
    let requestReset: () -> Void

    var body: some View {
        Group {
            Section {
                moduleRows
            }
            Section {
                HStack {
                    Spacer()
                    Button(L10n.string(.DataManagement.dataRestoreDefaults), action: requestReset)
                        .disabled(model.settings.menuConfiguration.modules == FinderMenuConfiguration.defaultModules)
                }
            }
        }
    }

    private var moduleRows: some View {
        ForEach(model.settings.menuConfiguration.modules) { module in
            HStack {
                FinderModuleToggle(model: model, moduleID: module.moduleID)
                Spacer()
                switch module.moduleID {
                case .newFile: settingsButton(L10n.string(.FinderSettings.menuTemplates), target: .templates)
                case .favoriteApps: settingsButton(L10n.string(.FinderSettings.menuApps), target: .applications)
                case .favoriteDirectories: settingsButton(L10n.string(.FinderSettings.menuFolders), target: .directories)
                case .fileOrganization: settingsButton(L10n.string(.FinderSettings.menuCopyMoveDestinations), target: .directories)
                case .terminal: FinderTerminalEditor(model: model).labelsHidden()
                default: EmptyView()
                }
                HStack(spacing: 4) {
                    ArcIconActionButton(title: L10n.string(.FinderSettings.menuMoveUp(String(describing: module.displayName))), symbol: .chevronUp) {
                        move(module, offset: -1)
                    }
                    .disabled(module.id == model.settings.menuConfiguration.modules.first?.id)
                    ArcIconActionButton(title: L10n.string(.FinderSettings.menuMoveDown(String(describing: module.displayName))), symbol: .chevronDown) {
                        move(module, offset: 1)
                    }
                    .disabled(module.id == model.settings.menuConfiguration.modules.last?.id)
                }
                .controlSize(.small)
            }
            if module.moduleID == .advancedTools, module.isEnabled {
                FinderRiskEditor(model: model)
            }
        }
    }

    private func settingsButton(_ title: String, target: FinderWorkspaceTab) -> some View {
        Button(title) { configure(target) }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string(.FinderSettings.menuConfigure(String(describing: target.title))))
    }

    private func move(_ module: FinderMenuModuleConfiguration, offset: Int) {
        model.update(actionName: L10n.string(.FinderSettings.menuReorderFinderMenu)) { settings in
            // 按身份查当前行，撤销或重排后不复用过期下标；禁用项也能预先安排位置。
            guard let index = settings.menuConfiguration.modules.firstIndex(where: { $0.id == module.id }) else { return }
            settings.menuConfiguration.moveModuleInDisplayOrder(from: index, offset: offset)
        }
    }
}

private struct FinderModuleToggle: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let moduleID: FinderMenuModuleID

    var body: some View {
        Toggle(moduleID.defaultTitle, isOn: Binding(
            get: { model.settings.menuConfiguration.module(moduleID).isEnabled },
            set: { enabled in model.update(actionName: L10n.string(.FinderSettings.menuConfigure(String(describing: moduleID.defaultTitle)))) {
                guard let index = $0.menuConfiguration.modules.firstIndex(where: { $0.moduleID == moduleID }) else { return }
                $0.menuConfiguration.modules[index].isEnabled = enabled
            } }
        ))
        .toggleStyle(.checkbox)
        .help(summary)
    }

    private var summary: String {
        switch moduleID {
        case .newFile: L10n.string(.FinderSettings.menuCreateFileCurrentFolder)
        case .favoriteApps: L10n.string(.FinderSettings.menuOpenSelectionSpecificApp)
        case .terminal: L10n.string(.FinderSettings.menuOpenTerminalCurrentFolder)
        case .copyPath: L10n.string(.FinderSettings.menuCopyFullPath)
        case .copyFileName: L10n.string(.FinderSettings.menuCopyFilename)
        case .favoriteDirectories: L10n.string(.FinderSettings.menuOpenFavoriteFoldersUsedCopy)
        case .fileOrganization: L10n.string(.FinderSettings.menuCopyMoveRenameCompressOrganizeFolders)
        case .fileInfo: L10n.string(.FinderSettings.menuCopyFileSizeTypeOtherInformation)
        case .copyHash: L10n.string(.FinderSettings.menuCalculateFileChecksums)
        case .convertTo: L10n.string(.FinderSettings.menuConvertImageFormats)
        case .folderIcon: L10n.string(.FinderSettings.menuSetRestoreFolderIcons)
        case .extractIcon: L10n.string(.FinderSettings.menuSaveItemSIcon)
        case .colorPicker: L10n.string(.FinderSettings.menuPickColorImage)
        case .advancedTools: L10n.string(.FinderSettings.menuHideUnhideHighRiskActionsRequire)
        }
    }
}
