import ArcKitFinder
import ArcKitPlatform
import Foundation

/// Worker 的唯一副作用分发入口；Host 仅复用准入校验和无副作用的剪贴板文本生成。
struct FinderCommandDispatcher {
    let targets: FinderCommandTargets
    let newFiles: FinderNewFileCommandExecutor
    let clipboard: FinderClipboardCommandExecutor
    let opening: FinderOpenCommandExecutor
    let files: FinderFileCommandExecutor
    let images: FinderImageCommandExecutor
    let scripts: FinderScriptCommandExecutor

    init(
        targets: FinderCommandTargets = FinderCommandTargets(),
        newFiles: FinderNewFileCommandExecutor = FinderNewFileCommandExecutor(),
        clipboard: FinderClipboardCommandExecutor = FinderClipboardCommandExecutor(),
        opening: FinderOpenCommandExecutor = FinderOpenCommandExecutor(),
        files: FinderFileCommandExecutor = FinderFileCommandExecutor(),
        images: FinderImageCommandExecutor = FinderImageCommandExecutor(),
        scripts: FinderScriptCommandExecutor = FinderScriptCommandExecutor()
    ) {
        self.targets = targets
        self.newFiles = newFiles
        self.clipboard = clipboard
        self.opening = opening
        self.files = files
        self.images = images
        self.scripts = scripts
    }

    func execute(_ request: FinderCommandRequest, settings: FinderRuntimeSettings) throws -> FinderCommandExecutionResult? {
        try Self.validateAvailability(of: request, settings: settings)
        ArcKitLog.append("processor dispatch id=\(request.id.uuidString) kind=\(request.kind.rawValue)")
        switch request.payload {
        case .createNewFile:
            return try newFiles.execute(request, settings: settings, targets: targets)
        case .copyPaths, .copyFileNames, .copyFileInfo, .copyHash, .copyPickedColor:
            return try clipboard.execute(request, targets: targets)
        case .openTerminal, .openWithApp, .openPath:
            return try opening.execute(request, targets: targets)
        case .copyToDirectory, .moveToDirectory, .hideFiles, .hideAllExceptFiles, .lockFiles,
             .deleteFiles, .archiveFiles, .moveIntoFolder, .batchRename, .flattenFolder:
            return try files.execute(request)
        case .setFolderIcon, .restoreFolderIcon, .extractIcon, .convertImage:
            return try images.execute(request)
        case .runScript:
            return try scripts.execute(request)
        }
    }

    static func validateAvailability(of request: FinderCommandRequest, settings: FinderRuntimeSettings) throws {
        guard settings.menuConfiguration.isEnabled else {
            throw FinderCommandExecutionError.featureDisabled(L10n.string(.FinderActions.dispatchFinderContextMenuEnhancementOff))
        }
        guard settings.menuConfiguration.module(request.kind.menuModule).isEnabled else {
            throw FinderCommandExecutionError.featureDisabled(L10n.string(.FinderActions.dispatchOffReopenContextMenu(String(describing: request.kind.menuModule.defaultTitle))))
        }
        try validateResourceChoice(of: request, configuration: settings.menuConfiguration)
        switch request.kind {
        case .lockFiles, .deleteFiles, .hideAllExceptFiles, .runScript:
            guard settings.menuConfiguration.highRiskActionsEnabled else {
                throw FinderCommandExecutionError.featureDisabled(L10n.string(.FinderActions.dispatchHighRiskActionsOffReopen))
            }
        default: break
        }
    }

    /// 模块启用后仍校验具体条目；已打开菜单中的条目被移除或停用后，Host 和 Worker 都必须拒绝。
    private static func validateResourceChoice(of request: FinderCommandRequest, configuration: FinderMenuConfiguration) throws {
        let isAvailable: Bool
        switch request.payload {
        case let .createNewFile(payload):
            isAvailable = configuration.enabledFileTemplates.contains { $0.id == payload.templateID }
        case let .openWithApp(payload):
            let requested = payload.favoriteApplication
            isAvailable = configuration.enabledFavoriteApplications.contains {
                $0.id == requested.id && $0.bundleIdentifier == requested.bundleIdentifier && $0.appPath == requested.appPath
            }
        case let .openPath(payload):
            guard let targetPath = payload.targetPath else {
                throw FinderCommandExecutionError.featureDisabled(L10n.string(.FinderActions.dispatchFavoriteFolderTargetExpiredReopenContext))
            }
            let target = URL(fileURLWithPath: targetPath).standardizedFileURL
            isAvailable = configuration.enabledFavoriteDirectories.contains { favorite in
                let root = URL(fileURLWithPath: favorite.path).standardizedFileURL
                if target.path == root.path { return true }
                guard target.deletingLastPathComponent().path == root.path else { return false }
                return FinderFavoriteDirectoryChildrenBuilder.children(for: favorite).contains { $0.path == target.path }
            }
        default: return
        }
        guard isAvailable else {
            throw FinderCommandExecutionError.featureDisabled(L10n.string(.FinderActions.dispatchSelectedEntryDisabledChanged))
        }
    }
}
