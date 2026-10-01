import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation
import os.log

public enum FinderCommandProcessorError: LocalizedError, Equatable {
    case clipboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            L10n.string(.FinderActions.commandClipboardFailed)
        }
    }
}

public typealias FinderDirectoryTransferTargetProvider = @MainActor (
    _ mode: FinderFileTransferMode,
    _ completion: @escaping @MainActor (String?) -> Void
) -> Void

/// 一次性批量重命名撤销凭证；超时、主动失效或执行一次后都不能再次使用。
@MainActor
public final class FinderBatchRenameUndoOffer {
    public let itemCount: Int
    public let expiresAt: Date

    private var handler: (@MainActor () -> Void)?

    init(
        itemCount: Int,
        expiresAt: Date,
        handler: @escaping @MainActor () -> Void
    ) {
        self.itemCount = itemCount
        self.expiresAt = expiresAt
        self.handler = handler
    }

    public var isAvailable: Bool {
        handler != nil && Date() < expiresAt
    }

    @discardableResult
    public func perform() -> Bool {
        guard Date() < expiresAt, let handler else {
            self.handler = nil
            return false
        }
        self.handler = nil
        handler()
        return true
    }

    public func invalidate() {
        handler = nil
    }
}

/// Finder Agent 侧命令处理器：接收 Finder 扩展投递的沙盒外文件操作并执行。
@MainActor
public final class FinderCommandProcessor {
    public var activityDidChange: (() -> Void)?
    private var activeRequests: Set<UUID> = []
    public var hasActiveCommands: Bool { !activeRequests.isEmpty }
    private let logger = Logger(subsystem: ArcKitConstants.appBundleIdentifier, category: "FinderCommandProcessor")
    private let settingsProvider: () -> FinderRuntimeSettings
    private let failureFeedbackHandler: @MainActor (_ title: String, _ message: String) -> Void
    private let successFeedbackHandler: @MainActor (_ title: String, _ message: String) -> Void
    private let clipboardWriter: @MainActor (String) -> Bool
    private let executionRuntimeStateHandler: @MainActor (FinderCommandExecutionRuntimeState) -> Void
    private let batchRenameUndoOfferHandler: @MainActor (FinderBatchRenameUndoOffer) -> Void
    private let directoryTransferTargetProvider: FinderDirectoryTransferTargetProvider
    private let workerClient: FinderOperationWorkerClient
    // Host 只直接生成路径/名称文本；所有文件副作用都交给独立 Worker。
    private let clipboard = FinderClipboardCommandExecutor()
    private var processedRequestIDs: [UUID] = []
    private var processedRequestIDSet: Set<UUID> = []

    public init(
        settingsProvider: @escaping () -> FinderRuntimeSettings,
        failureFeedbackHandler: (@MainActor (_ title: String, _ message: String) -> Void)? = nil,
        successFeedbackHandler: (@MainActor (_ title: String, _ message: String) -> Void)? = nil,
        clipboardWriter: (@MainActor (String) -> Bool)? = nil,
        executionRuntimeStateHandler: (@MainActor (FinderCommandExecutionRuntimeState) -> Void)? = nil,
        batchRenameUndoOfferHandler: (@MainActor (FinderBatchRenameUndoOffer) -> Void)? = nil,
        directoryTransferTargetProvider: FinderDirectoryTransferTargetProvider? = nil,
        workerClient: FinderOperationWorkerClient = FinderOperationWorkerClient()
    ) {
        self.settingsProvider = settingsProvider
        self.failureFeedbackHandler = failureFeedbackHandler ?? { title, message in
            FinderCommandHUDPresenter.shared.show(style: .failure, title: title, message: message)
        }
        self.successFeedbackHandler = successFeedbackHandler ?? { title, message in
            FinderCommandHUDPresenter.shared.show(style: .success, title: title, message: message)
        }
        self.clipboardWriter = clipboardWriter ?? { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        self.batchRenameUndoOfferHandler = batchRenameUndoOfferHandler ?? { offer in
            FinderCommandHUDPresenter.shared.showBatchRenameUndo(offer)
        }
        self.directoryTransferTargetProvider = directoryTransferTargetProvider ?? { mode, completion in
            FinderDirectoryTransferPrompt.present(mode: mode, completion: completion)
        }
        self.workerClient = workerClient
        self.executionRuntimeStateHandler = executionRuntimeStateHandler ?? { state in
            guard state.agentBundleIdentifier == ArcKitConstants.runtimeHostBundleIdentifier,
                  state.agentBundlePath == ArcKitConstants.installedRuntimeHostPath,
                  state.agentExecutablePath == ArcKitConstants.installedRuntimeHostExecutablePath
            else {
                return
            }
            do {
                try FinderCommandExecutionRuntimeStateStore().save(state)
            } catch {
                ArcKitLog.append(
                    "processor execution runtime state save failed id=\(state.requestID.uuidString) " +
                    "status=\(state.status.rawValue) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func handle(_ incomingRequest: FinderCommandRequest) {
        let startedAt = Date()
        recordExecutionState(
            request: incomingRequest,
            status: .started,
            startedAt: startedAt,
            completedAt: nil,
            result: nil,
            errorMessage: nil
        )
        do {
            try FinderCommandDispatcher.validateAvailability(of: incomingRequest, settings: settingsProvider())
        } catch {
            completeFailure(error, request: incomingRequest, startedAt: startedAt)
            return
        }
        if let mode = interactiveTransferMode(for: incomingRequest) {
            directoryTransferTargetProvider(mode) { [weak self] path in
                guard let self else { return }
                guard let path else {
                    self.recordInteractiveTransferCancellation(incomingRequest, startedAt: startedAt)
                    return
                }
                let prepared = self.applyingTransferTarget(path, to: incomingRequest)
                self.executePrepared(prepared, startedAt: startedAt)
            }
            return
        }

        executePrepared(incomingRequest, startedAt: startedAt)
    }

    private func executePrepared(
        _ request: FinderCommandRequest,
        startedAt: Date
    ) {
        // 选择目录等交互可能持续很久，执行时重新读取已提交设置，不能沿用打开面板前的开关。
        let settings = settingsProvider()
        do {
            try FinderCommandDispatcher.validateAvailability(of: request, settings: settings)
        } catch {
            completeFailure(error, request: request, startedAt: startedAt)
            return
        }
        ArcKitLog.append(
            "processor handle begin id=\(request.id.uuidString) kind=\(request.kind.rawValue) " +
            "targetPath=\(request.targetPath ?? "-") context=\(request.context.diagnosticDescription)"
        )
        // 已有明确目标的文本变换没有磁盘/AX 副作用，避免冷启动 Worker。
        if Self.canExecuteInline(request) {
            do { completeSuccess(try clipboard.execute(request, targets: FinderCommandTargets()), request: request, startedAt: startedAt) }
            catch { completeFailure(error, request: request, startedAt: startedAt) }
            return
        }
        workerClient.execute(request, settings: settings) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(executionResult):
                self.completeSuccess(executionResult, request: request, startedAt: startedAt)
            case let .failure(error):
                self.completeFailure(error, request: request, startedAt: startedAt)
            }
        }
    }

    public static func canExecuteInline(_ request: FinderCommandRequest) -> Bool {
        switch request.payload {
        case .copyPaths, .copyFileNames:
            return !request.sourcePaths.isEmpty || !request.context.selectedPaths.isEmpty
                || request.targetPath?.isEmpty == false || request.context.targetedPath?.isEmpty == false
        default: return false
        }
    }

    private func completeSuccess(
        _ result: FinderCommandExecutionResult?,
        request: FinderCommandRequest,
        startedAt: Date
    ) {
        do {
            if let result {
                if let clipboardText = result.clipboardText {
                    guard clipboardWriter(clipboardText) else {
                        ArcKitLog.append("processor clipboard failed id=\(request.id.uuidString) kind=\(request.kind.rawValue)")
                        throw FinderCommandProcessorError.clipboardWriteFailed
                    }
                    ArcKitLog.append("processor clipboard success id=\(request.id.uuidString) kind=\(request.kind.rawValue) resultKind=\(result.clipboardResultKind?.rawValue ?? "-")")
                    presentClipboardSuccess(for: request, resultKind: result.clipboardResultKind)
                }
                if let title = result.successFeedbackTitle,
                   let message = result.successFeedbackMessage {
                    successFeedbackHandler(title, message)
                }
                if let userMessage = result.userMessage {
                    ArcKitLog.append("processor user message id=\(request.id.uuidString) message=\(userMessage)")
                }
                if let receipt = result.batchRenameReceipt {
                    presentBatchRenameUndo(receipt, requestID: request.id)
                }
            }
            let completedAt = Date()
            recordExecutionState(
                request: request,
                status: .succeeded,
                startedAt: startedAt,
                completedAt: completedAt,
                result: result,
                errorMessage: nil
            )
            ArcKitLog.append("processor handle success id=\(request.id.uuidString) kind=\(request.kind.rawValue)")
        } catch {
            completeFailure(error, request: request, startedAt: startedAt)
        }
    }

    private func completeFailure(
        _ error: Error,
        request: FinderCommandRequest,
        startedAt: Date
    ) {
        let completedAt = Date()
        recordExecutionState(
            request: request,
            status: .failed,
            startedAt: startedAt,
            completedAt: completedAt,
            result: nil,
            errorMessage: error.localizedDescription
        )
        ArcKitLog.append(
            "processor handle failed id=\(request.id.uuidString) kind=\(request.kind.rawValue) " +
            "error=\(error.localizedDescription)"
        )
        logger.error("Finder command failed: \(String(describing: error), privacy: .public)")
        presentFailure(
            title: L10n.string(.FinderActions.commandFinderActionFailed),
            message: "\(actionTitle(for: request.kind))\n\n\(error.localizedDescription)"
        )
    }

    private func interactiveTransferMode(for request: FinderCommandRequest) -> FinderFileTransferMode? {
        switch request.payload {
        case let .copyToDirectory(payload) where payload.targetPath == nil:
            .copy
        case let .moveToDirectory(payload) where payload.targetPath == nil:
            .move
        default:
            nil
        }
    }

    private func applyingTransferTarget(_ path: String, to request: FinderCommandRequest) -> FinderCommandRequest {
        var prepared = request
        switch request.payload {
        case .copyToDirectory(var payload):
            payload.targetPath = path
            prepared.payload = .copyToDirectory(payload)
        case .moveToDirectory(var payload):
            payload.targetPath = path
            prepared.payload = .moveToDirectory(payload)
        default:
            break
        }
        return prepared
    }

    private func recordInteractiveTransferCancellation(
        _ request: FinderCommandRequest,
        startedAt: Date
    ) {
        let completedAt = Date()
        let result = FinderCommandExecutionResult(userMessage: L10n.string(.FinderActions.commandDestinationSelectionCancelledUser))
        recordExecutionState(
            request: request,
            status: .cancelled,
            startedAt: startedAt,
            completedAt: completedAt,
            result: result,
            errorMessage: nil
        )
        ArcKitLog.append(
            "processor handle cancelled id=\(request.id.uuidString) kind=\(request.kind.rawValue) reason=destination panel"
        )
    }

    public func process(_ request: FinderCommandRequest) {
        guard markRequestIfNeeded(request.id) else {
            ArcKitLog.append("processor skip duplicate id=\(request.id.uuidString) kind=\(request.kind.rawValue)")
            return
        }
        handle(request)
    }

    private func markRequestIfNeeded(_ id: UUID) -> Bool {
        guard !processedRequestIDSet.contains(id) else { return false }
        processedRequestIDSet.insert(id)
        processedRequestIDs.append(id)
        if processedRequestIDs.count > 200 {
            let removeCount = processedRequestIDs.count - 200
            let removed = processedRequestIDs.prefix(removeCount)
            processedRequestIDs.removeFirst(removeCount)
            processedRequestIDSet.subtract(removed)
        }
        return true
    }

    private func actionTitle(for kind: FinderCommandKind) -> String {
        switch kind {
        case .extensionLocalInfo: L10n.string(.FinderActions.commandExtensionLocalInformation)
        case .createNewFile: L10n.string(.FinderActions.pageNewFile)
        case .copyPaths: L10n.string(.FinderActions.commandCopyPath)
        case .copyFileNames: L10n.string(.FinderActions.menuCopyFilename)
        case .copyFileInfo: L10n.string(.FinderActions.commandCopyFileInfo)
        case .copyHash: L10n.string(.FinderActions.commandCopyChecksum)
        case .copyPickedColor: L10n.string(.FinderActions.commandPickColor)
        case .openTerminal: L10n.string(.FinderActions.commandOpenTerminal)
        case .openWithApp: L10n.string(.FinderActions.commandOpenApp)
        case .copyToDirectory: L10n.string(.FinderActions.commandCopyFolder)
        case .moveToDirectory: L10n.string(.FinderActions.commandMoveToFolder)
        case .openPath: L10n.string(.FinderActions.commandOpenPath)
        case .setFolderIcon: L10n.string(.FinderActions.commandSetFolderIcon)
        case .restoreFolderIcon: L10n.string(.FinderActions.commandRestoreFolderIcon)
        case .extractIcon: L10n.string(.FinderActions.commandExtractIcon)
        case .hideFiles: L10n.string(.FinderActions.commandHideUnhideFiles)
        case .hideAllExceptFiles: L10n.string(.FinderActions.commandHideOtherFiles)
        case .lockFiles: L10n.string(.FinderActions.commandLockUnlockFiles)
        case .deleteFiles: L10n.string(.FinderActions.commandPermanentlyDeleteFiles)
        case .archiveFiles: L10n.string(.FinderActions.commandCompressFiles)
        case .moveIntoFolder: L10n.string(.FinderActions.commandGroupInFolder)
        case .batchRename: L10n.string(.FinderActions.commandBatchRename)
        case .convertImage: L10n.string(.FinderActions.commandConvertImage)
        case .flattenFolder: L10n.string(.FinderActions.commandFlattenFolder)
        case .runScript: L10n.string(.FinderActions.commandRunScript)
        }
    }

    private func presentFailure(title: String, message: String) {
        failureFeedbackHandler(title, message)
    }

    private func presentClipboardSuccess(
        for request: FinderCommandRequest,
        resultKind: FinderClipboardResultKind?
    ) {
        let title: String
        switch resultKind {
        case .paths: title = L10n.string(.FinderActions.commandPathCopied)
        case .fileNames: title = L10n.string(.FinderActions.commandFilenameCopied)
        case .fileInfo: title = L10n.string(.FinderActions.commandFileInformationCopied)
        case .hash:
            if case let .copyHash(payload) = request.payload {
                title = L10n.string(.FinderActions.commandCopied(String(describing: payload.algorithm.title)))
            } else {
                title = L10n.string(.FinderActions.commandChecksumCopied)
            }
        case .color: title = L10n.string(.FinderActions.commandColorValueCopied)
        case nil: title = L10n.string(.FinderActions.commandContentCopied)
        }
        successFeedbackHandler(title, L10n.string(.FinderActions.commandWrittenSystemClipboardReady))
    }

    private func presentBatchRenameUndo(
        _ receipt: FinderBatchRenameExecutionReceipt,
        requestID: UUID
    ) {
        let itemCount = receipt.undoItems.count
        let successFeedbackHandler = self.successFeedbackHandler
        let failureFeedbackHandler = self.failureFeedbackHandler
        let offer = FinderBatchRenameUndoOffer(
            itemCount: itemCount,
            expiresAt: Date().addingTimeInterval(10)
        ) {
            do {
                let restored = try FinderBatchRenameUndoExecutor().undo(receipt)
                ArcKitLog.append(
                    "processor batch rename undo success id=\(requestID.uuidString) restored=\(restored.count)"
                )
                successFeedbackHandler(L10n.string(.FinderActions.commandBatchRenameUndone), L10n.string(.FinderActions.renameRestoredCount(Int(restored.count))))
            } catch {
                ArcKitLog.append(
                    "processor batch rename undo failed id=\(requestID.uuidString) error=\(error.localizedDescription)"
                )
                failureFeedbackHandler(L10n.string(.FinderActions.commandUndoRenameFailed), error.localizedDescription)
            }
        }
        ArcKitLog.append(
            "processor batch rename undo offered id=\(requestID.uuidString) count=\(itemCount) expiresIn=10s"
        )
        batchRenameUndoOfferHandler(offer)
    }

    private func recordExecutionState(
        request: FinderCommandRequest,
        status: FinderCommandExecutionRuntimeStatus,
        startedAt: Date,
        completedAt: Date?,
        result: FinderCommandExecutionResult?,
        errorMessage: String?
    ) {
        if completedAt == nil { activeRequests.insert(request.id) }
        else { activeRequests.remove(request.id) }
        activityDidChange?()
        let bundlePath = Bundle.main.bundleURL.path
        executionRuntimeStateHandler(FinderCommandExecutionRuntimeState(
            generatedAt: completedAt ?? startedAt,
            requestID: request.id,
            kind: request.kind,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            agentProcessID: ProcessInfo.processInfo.processIdentifier,
            agentBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            agentBundlePath: bundlePath,
            agentExecutablePath: Bundle.main.executableURL?.path ?? "",
            targetPath: request.targetPath,
            sourcePathCount: request.sourcePaths.count,
            createdPaths: result?.createdPaths ?? [],
            clipboardResultKind: result?.clipboardResultKind,
            userMessage: result?.userMessage,
            errorMessage: errorMessage
        ))
    }
}
