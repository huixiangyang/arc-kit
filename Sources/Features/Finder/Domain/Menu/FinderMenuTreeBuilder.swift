import ArcKitPlatform
import Foundation

public enum FinderMenuTreeBuilder {
    public static func buildEntries(state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        var result: [FinderMenuEntry] = []
        var previousGroup: FinderMenuPresentationGroup?
        for module in state.modules.filter(\.isEnabled).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let moduleEntries = entries(for: module, state: state, context: context)
            guard !moduleEntries.isEmpty else { continue }
            let group = module.moduleID.presentationGroup
            if let previousGroup, previousGroup != group {
                result.append(.separator(id: "separator.root.\(module.moduleID.rawValue)"))
            }
            result.append(contentsOf: moduleEntries)
            previousGroup = group
        }
        return result
    }

    private static func entries(
        for module: FinderMenuModuleConfiguration,
        state: FinderMenuTreeState,
        context: FinderMenuTargetContext
    ) -> [FinderMenuEntry] {
        switch module.moduleID {
        case .newFile:
            return newFileEntries(module: module, state: state, context: context)
        case .favoriteDirectories:
            return favoriteDirectoryEntries(module: module, state: state, context: context)
        case .favoriteApps:
            return favoriteAppEntries(module: module, state: state, context: context)
        case .terminal:
            return terminalEntries(module: module, state: state, context: context)
        case .fileOrganization:
            return fileOrganizationEntries(module: module, state: state, context: context)
        case .advancedTools:
            return advancedToolEntries(module: module, state: state, context: context)
        case .folderIcon:
            return submenu(module: module, context: context, children: [
                descriptor("arckit.folderIcon.set", L10n.string(.Finder.menuSetFolderIcon), module, .setFolderIcon, .setFolderIcon, .none, .selectedFolders, .image),
                descriptor("arckit.folderIcon.restore", L10n.string(.Finder.commandRestoreFolderIcon), module, .restoreFolderIcon, .restoreFolderIcon, .none, .selectedFolders, .rotateCcw),
            ])
        case .copyHash:
            return submenu(module: module, context: context, children: FileHashAlgorithm.allCases.map {
                descriptor("arckit.copyHash.\($0.rawValue)", L10n.string(.Finder.menuCopy(String(describing: $0.title))), module, .copyHash, .copyHash, .hashAlgorithm($0), .selectedFiles, .hash)
            })
        case .convertTo:
            return submenu(module: module, context: context, children: ["png", "jpg", "bmp", "tiff"].map {
                let title = $0 == "jpg" ? "JPEG" : $0.uppercased()
                return descriptor("arckit.convertImage.\($0)", title, module, .convertImage, .convertImage, .imageFormat($0), .selectedImages, .image)
            })
        case .colorPicker:
            return actionEntries([descriptor("arckit.\(module.moduleID.rawValue)", module.displayName, module, .copyPickedColor, .copyPickedColor, .none, .singleImage, module.moduleID.icon)], context: context)
        case .extractIcon:
            return actionEntries([descriptor("arckit.\(module.moduleID.rawValue)", module.displayName, module, .extractIcon, .extractIcon, .none, .singleItem, module.moduleID.icon)], context: context)
        case .fileInfo:
            return actionEntries([descriptor("arckit.\(module.moduleID.rawValue)", module.displayName, module, .copyFileInfo, .copyFileInfo, .none, .resolvedTarget, module.moduleID.icon)], context: context)
        case .copyPath:
            return actionEntries([descriptor("arckit.\(module.moduleID.rawValue)", module.displayName, module, .copyPaths, .copyPaths, .none, .resolvedTarget, module.moduleID.icon)], context: context)
        case .copyFileName:
            return actionEntries([descriptor("arckit.\(module.moduleID.rawValue)", module.displayName, module, .copyFileNames, .copyFileNames, .none, .resolvedTarget, module.moduleID.icon)], context: context)
        }
    }

    private static func newFileEntries(module: FinderMenuModuleConfiguration, state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        guard FinderActionVisibilityRule.currentDirectoryTarget.isVisible(in: context) else { return [] }
        let actions = state.fileTemplates.map { template in
            descriptor("arckit.newFile.\(template.id)", template.normalizedExtension.isEmpty ? template.localizedDisplayName : "\(template.localizedDisplayName) (.\(template.normalizedExtension))", module, .createNewFile, .createNewFile, .templateID(template.id), .currentDirectoryTarget, template.icon)
        }
        let pinnedIDs = Set(state.fileTemplates.filter(\.isPinnedToRootMenu).map { "arckit.newFile.\($0.id)" })
        return actionEntries(actions.filter { pinnedIDs.contains($0.actionID) }.map {
            var action = $0; action.title = L10n.string(.Finder.menuNew(String(describing: action.title))); return action
        }, context: context)
            + submenu(module: module, context: context, children: actions.filter { !pinnedIDs.contains($0.actionID) })
    }

    private static func favoriteDirectoryEntries(module: FinderMenuModuleConfiguration, state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        var actions: [FinderActionDescriptor] = []
        for favorite in state.favoriteDirectories {
            actions.append(descriptor("arckit.favoriteDirectories.favoriteDirectory.openPath.\(favorite.id.uuidString)",
                                      L10n.string(.Finder.menuOpen(String(describing: favorite.name))), module, .openPath, .openPath, .path(favorite.path), .always, .folder))
            actions.append(contentsOf: (state.favoriteDirectoryChildren[favorite.id] ?? []).map {
                descriptor("arckit.favoriteChild.\($0.path)", "\(favorite.name) / \($0.title)", module,
                           .openPath, .openPath, .path($0.path), .always, .folder)
            })
        }
        // 复制/移动目标统一归文件整理；这里仅用于导航，避免三层级联和重复入口。
        return submenu(module: module, context: context, children: actions)
    }

    private static func favoriteAppEntries(module: FinderMenuModuleConfiguration, state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        let actions = state.favoriteApplications.map { app in
            descriptor("arckit.favoriteApp.\(app.id.uuidString)", L10n.string(.Finder.menuOpenWith(String(describing: app.localizedDisplayName))), module, .openWithApp, .openWithApp, .favoriteApplication(app), TerminalApp(application: app) == nil ? .resolvedTarget : .terminalDirectoryTarget, .appWindow)
        }
        var entries: [FinderMenuEntry] = []
        let pinnedIDs = Set(state.favoriteApplications.filter(\.isPinnedToRootMenu).map { "arckit.favoriteApp.\($0.id.uuidString)" })
        entries.append(contentsOf: actionEntries(actions.filter { pinnedIDs.contains($0.actionID) }, context: context))
        let children = actions.filter { !pinnedIDs.contains($0.actionID) }.map { descriptor in
            var child = descriptor
            // 子菜单已有动作语境；首层快捷项仍保留完整动词，子项只显示应用名和图标。
            if case let .favoriteApplication(app) = child.payload { child.title = app.localizedDisplayName }
            return child
        }
        entries.append(contentsOf: submenu(module: module, context: context, children: children))
        return entries
    }

    private static func terminalEntries(
        module: FinderMenuModuleConfiguration,
        state: FinderMenuTreeState,
        context: FinderMenuTargetContext
    ) -> [FinderMenuEntry] {
        var children: [FinderActionDescriptor] = []
        // 终端只占一个根菜单入口；默认项排第一，不再额外生成首层快捷项。
        let terminals = state.availableTerminals.filter { $0 == state.defaultTerminal }
            + state.availableTerminals.filter { $0 != state.defaultTerminal }
        for terminal in terminals {
            let isDefault = terminal == state.defaultTerminal
            let open = descriptor(isDefault ? "arckit.terminal.default" : "arckit.terminal.\(terminal.rawValue).open",
                                  L10n.string(.Finder.menuOpenIn(String(describing: terminal.displayName))), module, .openTerminal, .openTerminal,
                                  .terminal(.init(terminalApp: terminal)), .terminalDirectoryTarget, .terminal)
            children.append(open)
            let mode: FinderTerminalOpenMode = terminal == .terminal ? .window : .tab
            let title = terminal == .terminal ? L10n.string(.Finder.menuNewWindow) : L10n.string(.Finder.menuNewTab)
            children.append(descriptor("arckit.terminal.\(terminal.rawValue).\(mode.rawValue)", "\(terminal.displayName) \(title)", module,
                                       .openTerminal, .openTerminal, .terminal(.init(terminalApp: terminal, openMode: mode)),
                                       .terminalDirectoryTarget, .terminal))
        }
        return submenu(module: module, context: context, children: children)
    }

    private static func fileOrganizationEntries(module: FinderMenuModuleConfiguration, state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        var children: [FinderMenuEntry] = []
        children.append(contentsOf: transferActions(module: module, title: L10n.string(.Finder.menuCopyTo), state: state, context: context, actionKind: .copyToDirectory, commandKind: .copyToDirectory))
        children.append(contentsOf: transferActions(module: module, title: L10n.string(.Finder.menuMove), state: state, context: context, actionKind: .moveToDirectory, commandKind: .moveToDirectory))
        children.append(contentsOf: actionEntries([
            descriptor("arckit.fileOrganization.copyToOtherDirectory", L10n.string(.Finder.menuCopyOtherLocation), module, .copyToDirectory, .copyToDirectory, .none, .selectedItems, .copy),
            descriptor("arckit.fileOrganization.moveToOtherDirectory", L10n.string(.Finder.menuMoveOtherLocation), module, .moveToDirectory, .moveToDirectory, .none, .selectedItems, .folderInput),
            descriptor("arckit.fileOrganization.archiveFiles.compress", L10n.string(.Finder.commandCompressFiles), module, .archiveFiles, .archiveFiles, .none, .selectedItems, .archive),
            descriptor("arckit.fileOrganization.moveIntoFolder.move", L10n.string(.Finder.menuMoveNewFolder), module, .moveIntoFolder, .moveIntoFolder, .none, .selectedItems, .folderPlus),
            descriptor("arckit.fileOrganization.batchRename.rename", L10n.string(.Finder.menuBatchRename), module, .batchRename, .batchRename, .none, .selectedItems, .textCursorInput),
            descriptor("arckit.fileOrganization.flattenFolder.flatten", L10n.string(.Finder.commandFlattenFolder), module, .flattenFolder, .flattenFolder, .none, .selectedFolders, .rows3),
        ], context: context))
        return submenu(module: module, context: context, children: children)
    }

    private static func advancedToolEntries(module: FinderMenuModuleConfiguration, state: FinderMenuTreeState, context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        var children = actionEntries([
            descriptor("arckit.advancedTools.hideFiles.hide", L10n.string(.Finder.menuHideSelectedFiles), module, .hideFiles, .hideFiles, .bool(true), .selectedItems, .eyeOff),
            descriptor("arckit.advancedTools.hideFiles.unhide", L10n.string(.Finder.menuUnhideFiles), module, .hideFiles, .hideFiles, .bool(false), .selectedItems, .eye),
        ], context: context)
        if state.highRiskActionsEnabled {
            children.append(contentsOf: actionEntries([
                descriptor("arckit.advancedTools.lockFiles.lock", L10n.string(.Finder.menuLock), module, .lockFiles, .lockFiles, .bool(true), .selectedItems, .lockKeyhole),
                descriptor("arckit.advancedTools.lockFiles.unlock", L10n.string(.Finder.menuUnlock), module, .lockFiles, .lockFiles, .bool(false), .selectedItems, .lockKeyholeOpen),
            ], context: context))
            children.append(contentsOf: actionEntries([
                descriptor("arckit.advancedTools.hideAllExceptFiles.hideOthers", L10n.string(.Finder.menuHideOtherItemsSameFolder), module, .hideAllExceptFiles, .hideAllExceptFiles, .none, .selectedItems, .eyeOff),
                descriptor("arckit.advancedTools.runScript.run", L10n.string(.Finder.menuRunScript), module, .runScript, .runScript, .none, .always, .terminal),
                descriptor("arckit.advancedTools.deleteFiles.delete", L10n.string(.Finder.menuDeletePermanently), module, .deleteFiles, .deleteFiles, .none, .selectedItems, .trash2),
            ], context: context))
        }
        children.append(.action(descriptor("arckit.advancedTools.showHiddenFilesInfo.info", L10n.string(.Finder.menuAboutHiddenFiles), module, .showHiddenFilesInfo, .extensionLocalInfo, .none, .always, .circleHelp)))
        return submenu(module: module, context: context, children: children)
    }

    private static func transferActions(module: FinderMenuModuleConfiguration, title: String, state: FinderMenuTreeState, context: FinderMenuTargetContext, actionKind: FinderMenuActionKind, commandKind: FinderCommandKind) -> [FinderMenuEntry] {
        actionEntries(state.favoriteDirectories.map {
            descriptor("arckit.\(module.moduleID.rawValue).favoriteDirectory.\(actionKind.rawValue).\($0.id.uuidString)",
                       "\(title) \($0.name)", module, actionKind, commandKind, .path($0.path), .selectedItems, .folder)
        }, context: context)
    }

    private static func submenu(module: FinderMenuModuleConfiguration, context: FinderMenuTargetContext, children: [FinderActionDescriptor]) -> [FinderMenuEntry] {
        submenu(id: "submenu.\(module.moduleID.rawValue)", title: module.displayName, moduleID: module.moduleID, icon: module.moduleID.icon, context: context, children: children)
    }

    private static func submenu(module: FinderMenuModuleConfiguration, context: FinderMenuTargetContext, children: [FinderMenuEntry]) -> [FinderMenuEntry] {
        let visible = children.filter { entry in
            if case let .action(descriptor) = entry {
                return descriptor.visibilityRule.isVisible(in: context)
            }
            return true
        }
        if visible.isEmpty { return [] }
        return [.submenu(id: "submenu.\(module.moduleID.rawValue)", title: module.displayName, moduleID: module.moduleID, icon: module.moduleID.icon, children: visible)]
    }

    private static func submenu(id: String, title: String, moduleID: FinderMenuModuleID?, icon: ArcIconName?, context: FinderMenuTargetContext, children: [FinderActionDescriptor]) -> [FinderMenuEntry] {
        let visible = actionEntries(children, context: context)
        if visible.isEmpty { return [] }
        return [.submenu(id: id, title: title, moduleID: moduleID, icon: icon, children: visible)]
    }

    private static func actionEntries(_ descriptors: [FinderActionDescriptor], context: FinderMenuTargetContext) -> [FinderMenuEntry] {
        descriptors
            .filter { $0.isEnabled && $0.visibilityRule.isVisible(in: context) }
            .filter { FinderMenuActionPolicy.allows($0) }
            .map(FinderMenuEntry.action)
    }

    private static func descriptor(
        _ actionID: String,
        _ title: String,
        _ module: FinderMenuModuleConfiguration,
        _ actionKind: FinderMenuActionKind,
        _ commandKind: FinderCommandKind,
        _ payload: FinderActionDescriptorPayload,
        _ visibilityRule: FinderActionVisibilityRule,
        _ icon: ArcIconName,
        isEnabled: Bool = true
    ) -> FinderActionDescriptor {
        FinderActionDescriptor(
            actionID: actionID,
            title: title,
            moduleID: module.moduleID,
            actionKind: actionKind,
            commandKind: commandKind,
            payload: payload,
            visibilityRule: visibilityRule,
            icon: icon,
            isEnabled: isEnabled
        )
    }
}
