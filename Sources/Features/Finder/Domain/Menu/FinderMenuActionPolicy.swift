import Foundation

/// 菜单准入只比较执行签名，不维护另一套展示标题、测试编号或高风险开关。
public enum FinderMenuActionPolicy {
    private struct Rule {
        let module: FinderMenuModuleID
        let action: FinderMenuActionKind
        let command: FinderCommandKind
        let visibility: FinderActionVisibilityRule

        init(_ module: FinderMenuModuleID, _ action: FinderMenuActionKind,
             _ command: FinderCommandKind, _ visibility: FinderActionVisibilityRule) {
            self.module = module
            self.action = action
            self.command = command
            self.visibility = visibility
        }
    }

    private static let rules: [Rule] = [
        Rule(.newFile, .createNewFile, .createNewFile, .currentDirectoryTarget),
        Rule(.favoriteDirectories, .openPath, .openPath, .always),
        Rule(.favoriteApps, .openWithApp, .openWithApp, .resolvedTarget),
        Rule(.favoriteApps, .openWithApp, .openWithApp, .terminalDirectoryTarget),
        Rule(.folderIcon, .setFolderIcon, .setFolderIcon, .selectedFolders),
        Rule(.folderIcon, .restoreFolderIcon, .restoreFolderIcon, .selectedFolders),
        Rule(.fileOrganization, .copyToDirectory, .copyToDirectory, .selectedItems),
        Rule(.fileOrganization, .moveToDirectory, .moveToDirectory, .selectedItems),
        Rule(.fileOrganization, .archiveFiles, .archiveFiles, .selectedItems),
        Rule(.fileOrganization, .moveIntoFolder, .moveIntoFolder, .selectedItems),
        Rule(.fileOrganization, .batchRename, .batchRename, .selectedItems),
        Rule(.fileOrganization, .flattenFolder, .flattenFolder, .selectedFolders),
        Rule(.convertTo, .convertImage, .convertImage, .selectedImages),
        Rule(.colorPicker, .copyPickedColor, .copyPickedColor, .singleImage),
        Rule(.extractIcon, .extractIcon, .extractIcon, .singleItem),
        Rule(.fileInfo, .copyFileInfo, .copyFileInfo, .resolvedTarget),
        Rule(.terminal, .openTerminal, .openTerminal, .terminalDirectoryTarget),
        Rule(.copyPath, .copyPaths, .copyPaths, .resolvedTarget),
        Rule(.copyFileName, .copyFileNames, .copyFileNames, .resolvedTarget),
        Rule(.copyHash, .copyHash, .copyHash, .selectedFiles),
        Rule(.advancedTools, .hideFiles, .hideFiles, .selectedItems),
        Rule(.advancedTools, .hideAllExceptFiles, .hideAllExceptFiles, .selectedItems),
        Rule(.advancedTools, .lockFiles, .lockFiles, .selectedItems),
        Rule(.advancedTools, .deleteFiles, .deleteFiles, .selectedItems),
        Rule(.advancedTools, .runScript, .runScript, .always),
        Rule(.advancedTools, .showArcKitRecoveryInfo, .extensionLocalInfo, .always),
        Rule(.advancedTools, .showHiddenFilesInfo, .extensionLocalInfo, .always),
    ]

    public static func allows(_ descriptor: FinderActionDescriptor) -> Bool {
        rules.contains {
            $0.module == descriptor.moduleID && $0.action == descriptor.actionKind
                && $0.command == descriptor.commandKind && $0.visibility == descriptor.visibilityRule
        }
    }
}
