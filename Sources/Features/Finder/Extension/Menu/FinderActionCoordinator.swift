import ArcKitFinder
import ArcKitPlatform
import Foundation

enum FinderActionDispatchOutcome: Equatable, Sendable {
    case extensionCompleted
    case commandQueued(UUID)
    case cancelled(String)
    case rejected(String)
}

/// Finder 菜单点击协调器。
///
/// 只负责本地用户交互、目标快照采集和命令投递；具体 payload 构造交给
/// `FinderCommandRequestFactory`，副作用执行交给常驻 Agent。
@MainActor
enum FinderActionCoordinator {
    private static let snapshotStore = FinderExtensionSnapshotStore()

    static func dispatch(
        _ action: FinderMenuActionRegistry.Registration?, menuItemTag: Int
    ) -> FinderActionDispatchOutcome {
        guard let action else {
            ArcKitLog.append("extension menu registration missing tag=\(menuItemTag)")
            FinderUserPromptService.feedback(title: L10n.string(.FinderExtension.commandFinderActionFailed), message: L10n.string(.FinderExtension.actionMenuExpiredReopenContextMenu))
            return .rejected(L10n.string(.FinderExtension.extensionMenuRegistrationExpiredTag(String(describing: menuItemTag))))
        }
        return dispatch(action.descriptor, target: action.target)
    }

    private static func dispatch(
        _ descriptor: FinderActionDescriptor,
        target: FinderContextCollector.ActionTargetSnapshot
    ) -> FinderActionDispatchOutcome {
        ArcKitLog.append(
            "extension descriptor action selected id=\(descriptor.actionID) kind=\(descriptor.actionKind.rawValue) command=\(descriptor.commandKind.rawValue)"
        )

        if descriptor.actionKind == .showArcKitRecoveryInfo {
            ArcKitLog.append("extension recovery info shown id=\(descriptor.actionID)")
            FinderUserPromptService.information(
                title: L10n.string(.FinderExtension.actionArcKitContextMenuNotReady),
                message: L10n.string(.FinderExtension.actionOpenArcKitMenuBar)
            )
            return .extensionCompleted
        }

        if descriptor.actionKind == .showHiddenFilesInfo {
            FinderUserPromptService.information(
                title: L10n.string(.FinderExtension.actionMacosHiddenFiles),
                message: L10n.string(.FinderExtension.actionPressCommandShiftFinderToggle)
            )
            return .extensionCompleted
        }

        guard descriptor.isEnabled else {
            ArcKitLog.append("extension descriptor rejected id=\(descriptor.actionID) reason=disabled \(descriptor.disabledReason ?? "-")")
            FinderUserPromptService.feedback(title: L10n.string(.FinderExtension.actionFinderActionUnavailable), message: descriptor.disabledReason ?? descriptor.title)
            return .rejected(descriptor.disabledReason ?? descriptor.title)
        }

        guard let settings = snapshotStore.load()?.runtimeSettings else {
            FinderUserPromptService.feedback(title: L10n.string(.FinderExtension.actionMenuConfigurationNotReady), message: L10n.string(.FinderExtension.actionReopenContextMenuRetry))
            return .rejected(L10n.string(.FinderExtension.actionTrustedMenuConfigurationReceivedYetMissing))
        }
        let supplement = makeSupplement(for: descriptor)
        guard supplement.wasNotCancelled else {
            return .cancelled(supplement.cancelReason ?? L10n.string(.FinderExtension.actionOperationCancelledUser))
        }

        do {
            guard let request = try FinderCommandRequestFactory.makeRequest(
                descriptor: descriptor,
                target: target,
                settings: settings,
                supplement: supplement.value
            ) else {
                return .rejected(L10n.string(.FinderExtension.actionActionProducedAgentCommandMissing))
            }
            try FinderCommandEnqueuer.enqueue(request)
            ArcKitLog.append("extension command enqueued id=\(request.id.uuidString) kind=\(request.kind.rawValue)")
            return .commandQueued(request.id)
        } catch {
            ArcKitLog.append("extension descriptor rejected id=\(descriptor.actionID) error=\(error.localizedDescription)")
            FinderUserPromptService.feedback(title: failureTitle(for: descriptor.actionKind), message: error.localizedDescription)
            return .rejected(error.localizedDescription)
        }
    }

    private struct SupplementResult {
        var value: FinderCommandRequestSupplement
        var wasNotCancelled: Bool
        var cancelReason: String?
    }

    private static func makeSupplement(for descriptor: FinderActionDescriptor) -> SupplementResult {
        var supplement = FinderCommandRequestSupplement()
        switch descriptor.actionKind {
        case .deleteFiles:
            guard FinderUserPromptService.confirmDestructiveDelete() else {
                ArcKitLog.append("extension descriptor cancelled id=\(descriptor.actionID) reason=delete confirmation")
                return SupplementResult(value: supplement, wasNotCancelled: false, cancelReason: L10n.string(.FinderExtension.actionPermanentDeletionCancelledUser))
            }
            supplement.destructiveActionConfirmed = true
        case .runScript:
            guard let scriptPath = FinderUserPromptService.chooseScriptPath() else {
                ArcKitLog.append("extension descriptor cancelled id=\(descriptor.actionID) reason=script panel")
                return SupplementResult(value: supplement, wasNotCancelled: false, cancelReason: L10n.string(.FinderExtension.actionScriptSelectionCancelledUser))
            }
            supplement.scriptPath = scriptPath
        case .moveIntoFolder:
            if case .folderName = descriptor.payload {
                break
            }
            guard let folderName = FinderUserPromptService.askFolderName() else {
                ArcKitLog.append("extension descriptor cancelled id=\(descriptor.actionID) reason=folder name")
                return SupplementResult(value: supplement, wasNotCancelled: false, cancelReason: L10n.string(.FinderExtension.actionFolderNameInputCancelledUser))
            }
            supplement.folderName = folderName
        default:
            break
        }
        return SupplementResult(value: supplement, wasNotCancelled: true, cancelReason: nil)
    }

    private static func failureTitle(for actionKind: FinderMenuActionKind) -> String {
        switch actionKind {
        case .createNewFile: L10n.string(.FinderExtension.actionCreateFileFailed)
        case .copyPaths: L10n.string(.FinderExtension.actionCopyPathFailed)
        case .copyFileNames: L10n.string(.FinderExtension.actionCopyFilenameFailed)
        case .copyFileInfo: L10n.string(.FinderExtension.actionCopyFileInformationFailed)
        case .copyPickedColor: L10n.string(.FinderExtension.actionPickColorFailed)
        case .copyHash: L10n.string(.FinderExtension.actionCopyChecksumFailed)
        case .openTerminal: L10n.string(.FinderExtension.actionOpenTerminalFailed)
        case .openWithApp: L10n.string(.FinderExtension.actionOpenAppFailed)
        case .copyToDirectory: L10n.string(.FinderExtension.actionCopyFailed)
        case .moveToDirectory: L10n.string(.FinderExtension.actionMoveFailed)
        case .openPath: L10n.string(.FinderExtension.actionOpenPathFailed)
        case .setFolderIcon: L10n.string(.FinderExtension.actionSetFolderIconFailed)
        case .restoreFolderIcon: L10n.string(.FinderExtension.actionRestoreFolderIconFailed)
        case .extractIcon: L10n.string(.FinderExtension.actionExtractIconFailed)
        case .hideFiles: L10n.string(.FinderExtension.actionHideUnhideFilesFailed)
        case .lockFiles: L10n.string(.FinderExtension.actionLockUnlockFilesFailed)
        case .deleteFiles: L10n.string(.FinderExtension.actionDeletePermanentlyFailed)
        case .archiveFiles: L10n.string(.FinderExtension.actionCompressFilesFailed)
        case .moveIntoFolder: L10n.string(.FinderExtension.actionMoveFolderFailed)
        case .batchRename: L10n.string(.FinderExtension.actionBatchRenameFailed)
        case .hideAllExceptFiles: L10n.string(.FinderExtension.actionHideOtherFilesFailed)
        case .showHiddenFilesInfo: L10n.string(.FinderExtension.actionShowInstructionsFailed)
        case .runScript: L10n.string(.FinderExtension.actionRunScriptFailed)
        case .convertImage: L10n.string(.FinderExtension.actionConvertImageFailed)
        case .flattenFolder: L10n.string(.FinderExtension.actionFlattenFolderFailed)
        case .showArcKitRecoveryInfo: L10n.string(.FinderExtension.actionShowRecoveryInstructionsFailed)
        }
    }
}
