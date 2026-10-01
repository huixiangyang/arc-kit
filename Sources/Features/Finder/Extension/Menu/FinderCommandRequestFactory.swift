import ArcKitFinder
import ArcKitPlatform
import Foundation

enum FinderCommandRequestFactoryError: LocalizedError {
    case missingTarget
    case ambiguousSelection
    case missingPayload(String)
    case emptySelection(String)
    case emptyFolderSelection(String)
    case missingSupplement(String)
    case highRiskDisabled(String)
    case missingUserConfirmation(String)

    var errorDescription: String? {
        switch self {
        case .missingTarget: L10n.string(.FinderExtension.requestFinderProvidedTargetMenuMissing)
        case .ambiguousSelection: L10n.string(.FinderExtension.requestActionSupportsOneItemSelect)
        case let .missingPayload(name):
            L10n.string(.FinderExtension.requestIncompleteMenuActionParameters(String(describing: name)))
        case let .emptySelection(action):
            L10n.string(.FinderExtension.requestSelectionMissing(String(describing: action)))
        case let .emptyFolderSelection(action):
            L10n.string(.FinderExtension.requestFolderSelectionRequired(String(describing: action)))
        case let .missingSupplement(name):
            L10n.string(.FinderExtension.requestRequiredInputMissing(String(describing: name)))
        case let .highRiskDisabled(action):
            L10n.string(.FinderExtension.requestHighRiskDisabled(String(describing: action)))
        case let .missingUserConfirmation(action):
            L10n.string(.FinderExtension.requestConfirmationRequired(String(describing: action)))
        }
    }
}

struct FinderCommandRequestSupplement {
    var scriptPath: String?
    var folderName: String?
    var destructiveActionConfirmed: Bool = false
}

/// 将菜单 descriptor、Finder 目标快照和用户补充输入转换为强类型 Agent 命令。
///
/// 这里是扩展侧唯一请求构造入口；业务动作禁止再直接读取 `selectedURLs`
/// 或自行拼 payload，避免空白处右键和真实选中项语义再次分叉。
enum FinderCommandRequestFactory {
    static func makeRequest(
        descriptor: FinderActionDescriptor,
        target: FinderContextCollector.ActionTargetSnapshot,
        settings: FinderRuntimeSettings,
        supplement: FinderCommandRequestSupplement = FinderCommandRequestSupplement()
    ) throws -> FinderCommandRequest? {
        let context = FinderMenuTargetContext(
            kind: target.targetKind, selectedItemCount: target.sourcePaths.count,
            hasCurrentDirectory: target.currentDirectoryPath != nil
        )
        guard descriptor.visibilityRule.isVisible(in: context) else {
            throw FinderCommandRequestFactoryError.missingTarget
        }
        try validateHighRiskActionIfNeeded(descriptor.actionKind, settings: settings)
        switch descriptor.actionKind {
        case .showArcKitRecoveryInfo, .showHiddenFilesInfo:
            return nil
        case .createNewFile:
            guard case let .templateID(templateID) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("templateID")
            }
            guard target.currentDirectoryPath != nil else { throw FinderCommandRequestFactoryError.missingTarget }
            return FinderCommandRequest(
                context: target.context,
                payload: .createNewFile(FinderNewFilePayload(
                    templateID: templateID,
                    targetPath: target.currentDirectoryPath,
                    targetResolutionPolicy: target.targetResolutionPolicy
                ))
            )
        case .copyPaths:
            return FinderCommandRequest(context: target.context, payload: .copyPaths(pathPayload(target)))
        case .copyFileNames:
            return FinderCommandRequest(context: target.context, payload: .copyFileNames(pathPayload(target)))
        case .copyFileInfo:
            return FinderCommandRequest(context: target.context, payload: .copyFileInfo(pathPayload(target)))
        case .copyPickedColor:
            return FinderCommandRequest(payload: .copyPickedColor(FinderColorPayload(
                sourcePaths: [try firstSelection(target, action: L10n.string(.FinderExtension.commandPickColor))],
                includeHash: true
            )))
        case .copyHash:
            guard case let .hashAlgorithm(algorithm) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("hashAlgorithm")
            }
            return FinderCommandRequest(payload: .copyHash(FinderHashPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandCopyChecksum)),
                algorithm: algorithm
            )))
        case .openTerminal:
            guard case let .terminal(payload) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("terminal")
            }
            return FinderCommandRequest(
                context: target.context,
                payload: .openTerminal(FinderTerminalPayload(
                    targetPath: target.currentDirectoryPath,
                    targetResolutionPolicy: target.targetResolutionPolicy,
                    terminalApp: payload.terminalApp,
                    openMode: payload.openMode
                ))
            )
        case .openWithApp:
            guard case let .favoriteApplication(app) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("favoriteApplication")
            }
            return FinderCommandRequest(
                context: target.context,
                payload: .openWithApp(FinderOpenWithAppPayload(
                    sourcePaths: target.sourcePaths,
                    targetPath: target.targetPath,
                    targetResolutionPolicy: target.targetResolutionPolicy,
                    favoriteApplication: app
                ))
            )
        case .copyToDirectory:
            return FinderCommandRequest(payload: .copyToDirectory(FinderDirectoryTransferPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.transferCopy)),
                targetPath: try transferTargetPath(descriptor, name: L10n.string(.FinderExtension.requestCopyDestinationFolder))
            )))
        case .moveToDirectory:
            return FinderCommandRequest(payload: .moveToDirectory(FinderDirectoryTransferPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.transferMove)),
                targetPath: try transferTargetPath(descriptor, name: L10n.string(.FinderExtension.requestMoveDestinationFolder))
            )))
        case .openPath:
            return FinderCommandRequest(payload: .openPath(FinderPathPayload(
                targetPath: try pathPayloadValue(descriptor, name: "open path")
            )))
        case .setFolderIcon:
            return FinderCommandRequest(payload: .setFolderIcon(FinderFolderIconPayload(
                sourcePaths: try folderSelection(target, action: L10n.string(.FinderExtension.commandSetFolderIcon))
            )))
        case .restoreFolderIcon:
            return FinderCommandRequest(payload: .restoreFolderIcon(FinderSelectionPayload(
                sourcePaths: try folderSelection(target, action: L10n.string(.FinderExtension.commandRestoreFolderIcon))
            )))
        case .extractIcon:
            return FinderCommandRequest(payload: .extractIcon(FinderExtractIconPayload(
                sourcePaths: [try firstSelection(target, action: L10n.string(.FinderExtension.commandExtractIcon))]
            )))
        case .hideFiles:
            guard case let .bool(hidden) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("hidden bool")
            }
            return FinderCommandRequest(payload: .hideFiles(FinderToggleSelectionPayload(
                sourcePaths: try selection(target, action: hidden ? L10n.string(.FinderExtension.requestHideFiles) : L10n.string(.FinderExtension.menuUnhideFiles)),
                enabled: hidden
            )))
        case .lockFiles:
            guard case let .bool(locked) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("lock bool")
            }
            return FinderCommandRequest(payload: .lockFiles(FinderToggleSelectionPayload(
                sourcePaths: try selection(target, action: locked ? L10n.string(.FinderExtension.requestLockFiles) : L10n.string(.FinderExtension.requestUnlockFiles)),
                enabled: locked
            )))
        case .deleteFiles:
            guard supplement.destructiveActionConfirmed else {
                throw FinderCommandRequestFactoryError.missingUserConfirmation(L10n.string(.FinderExtension.menuDeletePermanently))
            }
            return FinderCommandRequest(payload: .deleteFiles(FinderConfirmedSelectionPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.menuDeletePermanently)),
                userConfirmed: true
            )))
        case .archiveFiles:
            return FinderCommandRequest(payload: .archiveFiles(FinderSelectionPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandCompressFiles))
            )))
        case .moveIntoFolder:
            let folderName: String
            if case let .folderName(name) = descriptor.payload, !name.isEmpty {
                folderName = name
            } else if let name = supplement.folderName, !name.isEmpty {
                folderName = name
            } else {
                throw FinderCommandRequestFactoryError.missingSupplement(L10n.string(.FinderExtension.requestFolderName))
            }
            return FinderCommandRequest(payload: .moveIntoFolder(FinderMoveIntoFolderPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandGroupInFolder)),
                folderName: folderName
            )))
        case .batchRename:
            return FinderCommandRequest(payload: .batchRename(FinderBatchRenamePayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandBatchRename))
            )))
        case .hideAllExceptFiles:
            return FinderCommandRequest(payload: .hideAllExceptFiles(FinderSelectionPayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandHideOtherFiles))
            )))
        case .runScript:
            guard let scriptPath = supplement.scriptPath else {
                throw FinderCommandRequestFactoryError.missingSupplement(L10n.string(.FinderExtension.requestScriptPath))
            }
            return FinderCommandRequest(payload: .runScript(FinderRunScriptPayload(
                scriptPath: try FinderScriptValidation.validate(scriptPath)
            )))
        case .convertImage:
            guard case let .imageFormat(format) = descriptor.payload else {
                throw FinderCommandRequestFactoryError.missingPayload("image format")
            }
            return FinderCommandRequest(payload: .convertImage(FinderConvertImagePayload(
                sourcePaths: try selection(target, action: L10n.string(.FinderExtension.commandConvertImage)),
                format: format
            )))
        case .flattenFolder:
            return FinderCommandRequest(payload: .flattenFolder(FinderSelectionPayload(
                sourcePaths: try folderSelection(target, action: L10n.string(.FinderExtension.commandFlattenFolder))
            )))
        }
    }

    private static func pathPayload(_ target: FinderContextCollector.ActionTargetSnapshot) -> FinderPathPayload {
        FinderPathPayload(
            sourcePaths: target.sourcePaths,
            targetPath: target.targetPath,
            targetResolutionPolicy: target.targetResolutionPolicy
        )
    }

    private static func transferTargetPath(
        _ descriptor: FinderActionDescriptor,
        name: String
    ) throws -> String? {
        switch descriptor.payload {
        case let .path(path):
            return path
        case .none:
            return nil
        default:
            throw FinderCommandRequestFactoryError.missingPayload(name)
        }
    }

    private static func validateHighRiskActionIfNeeded(_ actionKind: FinderMenuActionKind, settings: FinderRuntimeSettings) throws {
        guard actionKind.requiresHighRiskActionsEnabled else { return }
        guard settings.menuConfiguration.highRiskActionsEnabled else {
            throw FinderCommandRequestFactoryError.highRiskDisabled(actionKind.highRiskDisplayName)
        }
    }

    private static func pathPayloadValue(_ descriptor: FinderActionDescriptor, name: String) throws -> String {
        guard case let .path(path) = descriptor.payload else {
            throw FinderCommandRequestFactoryError.missingPayload(name)
        }
        return path
    }

    private static func selection(_ target: FinderContextCollector.ActionTargetSnapshot, action: String) throws -> [String] {
        guard !target.sourcePaths.isEmpty else {
            throw FinderCommandRequestFactoryError.emptySelection(action)
        }
        return target.sourcePaths
    }

    private static func firstSelection(_ target: FinderContextCollector.ActionTargetSnapshot, action: String) throws -> String {
        guard target.sourcePaths.count <= 1 else { throw FinderCommandRequestFactoryError.ambiguousSelection }
        guard let first = target.sourcePaths.first else {
            throw FinderCommandRequestFactoryError.emptySelection(action)
        }
        return first
    }

    private static func folderSelection(_ target: FinderContextCollector.ActionTargetSnapshot, action: String) throws -> [String] {
        // 扩展沙盒不能再次 stat 筛掉部分选择；Host 执行前会校验完整清单。
        guard target.targetKind == .folders, !target.sourcePaths.isEmpty else {
            throw FinderCommandRequestFactoryError.emptyFolderSelection(action)
        }
        return target.sourcePaths
    }

}

private extension FinderMenuActionKind {
    var requiresHighRiskActionsEnabled: Bool {
        switch self {
        case .lockFiles, .deleteFiles, .hideAllExceptFiles, .runScript:
            true
        default:
            false
        }
    }

    var highRiskDisplayName: String {
        switch self {
        case .lockFiles: L10n.string(.FinderExtension.requestLockUnlock)
        case .deleteFiles: L10n.string(.FinderExtension.menuDeletePermanently)
        case .hideAllExceptFiles: L10n.string(.FinderExtension.menuHideOtherItemsSameFolder)
        case .runScript: L10n.string(.FinderExtension.commandRunScript)
        default: rawValue
        }
    }
}
