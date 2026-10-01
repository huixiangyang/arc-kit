import ArcKitFinder
import ArcKitPlatform
import Foundation
import Darwin

/// 文件动作拥有写入、回滚和结果校验；不持有剪贴板、图像或工作区依赖。
struct FinderFileCommandExecutor {
    let fileManager: FileManager
    let process: FinderProcessRunner
    let batchRenameRuleProvider: ([String]) -> FinderBatchRenameRule?
    private var organization: FinderFileOrganizationExecutor { FinderFileOrganizationExecutor(fileManager: fileManager) }

    init(
        fileManager: FileManager = .default,
        process: FinderProcessRunner = FinderProcessRunner(),
        batchRenameRuleProvider: @escaping ([String]) -> FinderBatchRenameRule? = { _ in nil }
    ) {
        self.fileManager = fileManager
        self.process = process
        self.batchRenameRuleProvider = batchRenameRuleProvider
    }

    func execute(_ request: FinderCommandRequest) throws -> FinderCommandExecutionResult? {
        switch request.payload {
        case let .copyToDirectory(payload):
            return try executeTransfer(payload, mode: .copy)
        case let .moveToDirectory(payload):
            return try executeTransfer(payload, mode: .move)
        case let .hideFiles(payload):
            let urls = payload.sourcePaths.map { URL(fileURLWithPath: $0) }
            try changeFlags(urls, flag: payload.enabled ? "hidden" : "nohidden", mask: UInt32(UF_HIDDEN), expected: payload.enabled)
        case .hideAllExceptFiles:
            try hideAllExcept(sourceURLs: try FinderCommandTargets.sourceURLs(request))
        case let .lockFiles(payload):
            let urls = payload.sourcePaths.map { URL(fileURLWithPath: $0) }
            try changeFlags(urls, flag: payload.enabled ? "uchg" : "nouchg", mask: UInt32(UF_IMMUTABLE), expected: payload.enabled)
        case let .deleteFiles(payload):
            guard payload.userConfirmed else {
                throw FinderCommandExecutionError.destructiveActionNotConfirmed(L10n.string(.FinderActions.menuDeletePermanently))
            }
            for url in try FinderCommandTargets.sourceURLs(request) {
                try fileManager.removeItem(at: url)
                try verifyItemMissing(url, actionName: L10n.string(.FinderActions.menuDeletePermanently))
            }
        case .archiveFiles:
            let destination = try FinderArchiveCommandExecutor(fileManager: fileManager, process: process)
                .archive(FinderCommandTargets.sourceURLs(request))
            return FinderCommandExecutionResult(createdPaths: [destination.path], userMessage: L10n.string(.FinderActions.fileFilesCompressed))
        case let .moveIntoFolder(payload):
            let destination = try organization.group(FinderCommandTargets.sourceURLs(request), folderName: payload.folderName)
            return FinderCommandExecutionResult(createdPaths: [destination.path], userMessage: L10n.string(.FinderActions.fileMovedFolder))
        case let .batchRename(payload):
            let sourcePaths = try FinderCommandTargets.nonEmptySourcePaths(request)
            guard let rule = payload.rule ?? batchRenameRuleProvider(sourcePaths) else {
                ArcKitLog.append("processor batch rename cancelled targetCount=\(sourcePaths.count)")
                return FinderCommandExecutionResult(userMessage: L10n.string(.FinderActions.fileBatchRenameCancelled))
            }
            let plan = try FinderBatchRenamePlanner(fileManager: fileManager).makePlan(
                sourcePaths: sourcePaths,
                rule: rule
            )
            let receipt = try FinderBatchRenameExecutor(fileManager: fileManager).execute(plan)
            let destinations = receipt.destinationURLs
            ArcKitLog.append(
                "processor batch rename success changed=\(destinations.count) selected=\(sourcePaths.count) mode=\(rule.mode.rawValue)"
            )
            return FinderCommandExecutionResult(
                createdPaths: destinations.map(\.path),
                userMessage: L10n.string(.FinderActions.renameCompletedCount(Int(destinations.count))),
                batchRenameReceipt: receipt
            )
        case .flattenFolder:
            let destinations = try organization.flatten(FinderCommandTargets.sourceURLs(request))
            return FinderCommandExecutionResult(createdPaths: destinations.map(\.path), userMessage: L10n.string(.FinderActions.fileFolderFlattened))
        default:
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.fileFileExecutorReceivedUnexpectedCommand(String(describing: request.kind.rawValue))))
        }
        return nil
    }

    private func executeTransfer(
        _ payload: FinderDirectoryTransferPayload,
        mode: FinderFileTransferMode
    ) throws -> FinderCommandExecutionResult {
        guard let targetPath = payload.targetPath else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.fileDestinationFolderSelectedMissing(String(describing: mode.actionTitle))))
        }
        let plan = try FinderFileTransferPlanner(fileManager: fileManager).makePlan(
            sourcePaths: payload.sourcePaths,
            destinationDirectoryPath: targetPath,
            mode: mode
        )
        let destinations = try FinderFileTransferExecutor(fileManager: fileManager).execute(plan)
        let destinationName = plan.destinationDirectory.lastPathComponent.isEmpty
            ? plan.destinationDirectory.path
            : plan.destinationDirectory.lastPathComponent
        return FinderCommandExecutionResult(
            createdPaths: destinations.map(\.path),
            userMessage: L10n.string(.FinderActions.fileCompletedWithDestination(String(describing: mode.actionTitle), String(describing: destinations.count), String(describing: destinationName))),
            successFeedbackTitle: L10n.string(.FinderActions.fileCompleted(String(describing: mode.actionTitle), String(describing: destinations.count))),
            successFeedbackMessage: L10n.string(.FinderActions.fileDestination(String(describing: destinationName)))
        )
    }

    private func changeFlags(_ urls: [URL], flag: String, mask: UInt32, expected: Bool) throws {
        guard !urls.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        // -h 与 lstat 均操作目录项自身，不能沿链接修改未选中的目标。
        try process.run(executable: "/usr/bin/chflags", arguments: ["-h", flag] + urls.map(\.path))
        for url in urls {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (status.st_flags & mask != 0) == expected else {
                throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.fileFlagUnconfirmed(String(describing: url.path))))
            }
        }
    }

    private func verifyItemMissing(_ url: URL, actionName: String) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.fileSourceItemStillExists(String(describing: actionName), String(describing: url.path))))
        }
    }

    private func hideAllExcept(sourceURLs: [URL]) throws {
        let parent = try FinderFileSelection.commonParent(of: sourceURLs, fileManager: fileManager)
        let selected = Set(sourceURLs.map(\.lastPathComponent))
        let children = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let targets = children.filter { !selected.contains($0.lastPathComponent) }
        guard !targets.isEmpty else { return }
        try changeFlags(targets, flag: "hidden", mask: UInt32(UF_HIDDEN), expected: true)
    }
}
