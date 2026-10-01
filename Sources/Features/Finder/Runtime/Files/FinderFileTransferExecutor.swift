import ArcKitPlatform
import ArcKitFinder
import Foundation
import Darwin

/// 文件写入与失败回滚仅由 Finder 后台执行，共用模块只保留计划和数据类型。
public struct FinderFileTransferExecutor {
    public typealias CopyItem = (URL, URL) throws -> Void
    public typealias MoveItem = (URL, URL) throws -> Void
    public typealias RemoveItem = (URL) throws -> Void

    private let fileManager: FileManager
    private let copyItem: CopyItem
    private let moveItem: MoveItem
    private let removeItem: RemoveItem
    private let removeEmptyDirectory: RemoveItem

    public init(
        fileManager: FileManager = .default,
        copyItem: CopyItem? = nil,
        moveItem: MoveItem? = nil,
        removeItem: RemoveItem? = nil,
        removeEmptyDirectory: RemoveItem? = nil
    ) {
        self.fileManager = fileManager
        self.copyItem = copyItem ?? { try fileManager.copyItem(at: $0, to: $1) }
        self.moveItem = moveItem ?? { try fileManager.moveItem(at: $0, to: $1) }
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
        self.removeEmptyDirectory = removeEmptyDirectory ?? { url in
            // 只删除空目录；不能递归移除执行期间新出现的文件。
            guard Darwin.rmdir(url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    public func execute(_ plan: FinderFileTransferPlan, removingEmptyDirectories directories: [URL] = []) throws -> [URL] {
        guard !plan.items.isEmpty || !directories.isEmpty else { throw FinderFileTransferError.emptySelection }
        guard directories.isEmpty || plan.mode == .move else {
            throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionSourceDeletionRejected))
        }
        let directoryBackup = try directories.isEmpty ? nil : fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: plan.destinationDirectory, create: true
        )
        var preserveDirectoryBackup = false
        defer {
            if let directoryBackup, !preserveDirectoryBackup { try? fileManager.removeItem(at: directoryBackup) }
        }
        var completed: [FinderFileTransferPlanItem] = []
        var inFlight: FinderFileTransferPlanItem?
        var removedDirectories: [Int] = []

        do {
            for item in plan.items {
                guard !itemExists(item.destinationURL) else {
                    throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionDestinationOccupied(String(describing: item.destinationURL.path))))
                }
                inFlight = item
                switch plan.mode {
                case .copy:
                    try copyItem(item.sourceURL, item.destinationURL)
                case .move:
                    try moveItem(item.sourceURL, item.destinationURL)
                }
                completed.append(item)
                inFlight = nil
                try verifyCompleted(item, mode: plan.mode)
            }
            for (index, directory) in directories.enumerated() {
                if let directoryBackup {
                    // 子项已移动；备份空目录自身的权限、扩展属性等，失败恢复不重建白板目录。
                    guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                        throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionNewItemsAppearedFolderFlattening(String(describing: directory.path))))
                    }
                    try fileManager.copyItem(at: directory, to: directoryBackup.appendingPathComponent(String(index)))
                }
                try removeEmptyDirectory(directory)
                removedDirectories.append(index)
                guard !itemExists(directory) else {
                    throw FinderFileTransferError.executionFailed(action: L10n.string(.FinderActions.commandFlattenFolder), reason: L10n.string(.FinderActions.transferExecutionSourceFolderStillExists(String(describing: directory.path))))
                }
            }
            return plan.items.map(\.destinationURL)
        } catch {
            let originalError = error.localizedDescription
            var rollbackErrors: [String] = []
            if let inFlight, itemExists(inFlight.destinationURL) || !itemExists(inFlight.sourceURL) {
                // 文件系统抛错也可能已经写入部分内容；保留现场，不能假称此步骤没有副作用。
                rollbackErrors.append(L10n.string(.FinderActions.transferExecutionStepSResultUncertainFailed(String(describing: inFlight.sourceURL.path), String(describing: inFlight.destinationURL.path))))
            }
            for index in removedDirectories.reversed() {
                do {
                    let directory = directories[index]
                    guard !itemExists(directory) else {
                        throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionOriginalFolderLocationOccupied(String(describing: directory.path))))
                    }
                    if let directoryBackup {
                        try fileManager.moveItem(at: directoryBackup.appendingPathComponent(String(index)), to: directory)
                    }
                } catch {
                    preserveDirectoryBackup = true
                    rollbackErrors.append(L10n.string(.FinderActions.transferExecutionFolderBackup(String(describing: directories[index].path), String(describing: error.localizedDescription), String(describing: directoryBackup?.path ?? "-"))))
                }
            }
            for item in completed.reversed() {
                do {
                    switch plan.mode {
                    case .copy:
                        guard itemExists(item.sourceURL) else {
                            throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionSourceMissing(String(describing: item.destinationURL.path))))
                        }
                        if itemExists(item.destinationURL) { try removeItem(item.destinationURL) }
                        guard !itemExists(item.destinationURL), itemExists(item.sourceURL) else {
                            throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionCopyRollbackUnconfirmed(String(describing: item.destinationURL.path))))
                        }
                    case .move:
                        guard itemExists(item.destinationURL), !itemExists(item.sourceURL) else {
                            throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionMoveRollbackLocationChanged(String(describing: item.sourceURL.path), String(describing: item.destinationURL.path))))
                        }
                        try moveItem(item.destinationURL, item.sourceURL)
                        guard itemExists(item.sourceURL), !itemExists(item.destinationURL) else {
                            throw FinderFileTransferError.invalidDestination(L10n.string(.FinderActions.transferExecutionMoveRollbackUnconfirmed(String(describing: item.sourceURL.path))))
                        }
                    }
                } catch {
                    rollbackErrors.append(
                        "\(item.destinationURL.lastPathComponent)：\(error.localizedDescription)"
                    )
                }
            }
            if rollbackErrors.isEmpty {
                throw FinderFileTransferError.executionFailed(
                    action: plan.mode.actionTitle,
                    reason: originalError
                )
            }
            throw FinderFileTransferError.rollbackFailed(
                action: plan.mode.actionTitle,
                original: originalError,
                rollback: rollbackErrors.joined(separator: "；")
            )
        }
    }

    private func itemExists(_ url: URL) -> Bool {
        // 断开的符号链接也占用目录项，不能当成空闲路径或丢失文件。
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func verifyCompleted(
        _ item: FinderFileTransferPlanItem,
        mode: FinderFileTransferMode
    ) throws {
        guard itemExists(item.destinationURL) else {
            throw FinderFileTransferError.executionFailed(
                action: mode.actionTitle,
                reason: L10n.string(.FinderActions.transferExecutionDestinationMissing(String(describing: item.destinationURL.path)))
            )
        }
        switch mode {
        case .copy:
            guard itemExists(item.sourceURL) else {
                throw FinderFileTransferError.executionFailed(
                    action: mode.actionTitle,
                    reason: L10n.string(.FinderActions.transferExecutionSourceItemMissingCopying(String(describing: item.sourceURL.path)))
                )
            }
        case .move:
            guard !itemExists(item.sourceURL) else {
                throw FinderFileTransferError.executionFailed(
                    action: mode.actionTitle,
                    reason: L10n.string(.FinderActions.transferExecutionSourceItemStillExistsMoving(String(describing: item.sourceURL.path)))
                )
            }
        }
    }
}
