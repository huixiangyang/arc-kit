import ArcKitPlatform
import ArcKitFinder
import Foundation

/// 文件写入与失败回滚仅由 Finder 后台执行，共用模块只保留计划和数据类型。
public struct FinderBatchRenameExecutor {
    public typealias MoveItem = @Sendable (URL, URL) throws -> Void

    private let fileManager: FileManager
    private let moveItem: MoveItem
    private let makeTemporaryName: @Sendable () -> String

    public init(
        fileManager: FileManager = .default,
        moveItem: MoveItem? = nil,
        makeTemporaryName: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.fileManager = fileManager
        self.moveItem = moveItem ?? { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
        self.makeTemporaryName = makeTemporaryName
    }

    public func execute(_ plan: FinderBatchRenamePlan) throws -> FinderBatchRenameExecutionReceipt {
        let changedItems = plan.changedItems
        guard !changedItems.isEmpty else { throw FinderBatchRenameError.noChanges }

        struct StagedItem {
            let planItem: FinderBatchRenamePlanItem
            let temporaryURL: URL
            var finalized: Bool
        }
        var staged: [StagedItem] = []

        do {
            for item in changedItems {
                let temporaryURL = try uniqueTemporaryURL(for: item.sourceURL)
                try moveItem(item.sourceURL, temporaryURL)
                staged.append(StagedItem(planItem: item, temporaryURL: temporaryURL, finalized: false))
            }
            for index in staged.indices {
                try moveItem(staged[index].temporaryURL, staged[index].planItem.destinationURL)
                staged[index].finalized = true
            }
            for item in changedItems {
                guard fileManager.fileExists(atPath: item.destinationURL.path),
                      !fileManager.fileExists(atPath: item.sourceURL.path)
                else {
                    throw FinderBatchRenameError.executionFailed(L10n.string(.FinderActions.renameExecutionNameVerificationFailed(String(describing: item.destinationURL.lastPathComponent))))
                }
            }
            let undoItems = try changedItems.map { item in
                FinderBatchRenameUndoItem(
                    currentURL: item.destinationURL,
                    originalURL: item.sourceURL,
                    isDirectory: item.isDirectory,
                    identity: try fileIdentity(at: item.destinationURL)
                )
            }
            return FinderBatchRenameExecutionReceipt(undoItems: undoItems)
        } catch {
            let originalError = error.localizedDescription
            var rollbackErrors: [String] = []
            for item in staged.reversed() {
                let currentURL = item.finalized ? item.planItem.destinationURL : item.temporaryURL
                guard fileManager.fileExists(atPath: currentURL.path) else { continue }
                do {
                    try moveItem(currentURL, item.planItem.sourceURL)
                } catch {
                    rollbackErrors.append("\(currentURL.lastPathComponent) → \(item.planItem.sourceURL.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if rollbackErrors.isEmpty {
                throw FinderBatchRenameError.executionFailed(originalError)
            }
            throw FinderBatchRenameError.rollbackFailed(
                original: originalError,
                rollback: rollbackErrors.joined(separator: "；")
            )
        }
    }

    private func uniqueTemporaryURL(for sourceURL: URL) throws -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        for _ in 0 ..< 20 {
            let candidate = directory.appendingPathComponent(".arckit-rename-\(makeTemporaryName()).tmp")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw FinderBatchRenameError.executionFailed(L10n.string(.FinderActions.renameExecutionTemporaryNameFailed))
    }

    private func fileIdentity(at url: URL) throws -> FinderFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else {
            throw FinderBatchRenameError.executionFailed(L10n.string(.FinderActions.renameExecutionIdentityReadFailed(String(describing: url.lastPathComponent))))
        }
        return FinderFileIdentity(
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value
        )
    }
}

public struct FinderBatchRenameUndoExecutor {
    private let fileManager: FileManager
    private let moveItem: FinderBatchRenameExecutor.MoveItem?

    public init(
        fileManager: FileManager = .default,
        moveItem: FinderBatchRenameExecutor.MoveItem? = nil
    ) {
        self.fileManager = fileManager
        self.moveItem = moveItem
    }

    public func undo(_ receipt: FinderBatchRenameExecutionReceipt) throws -> [URL] {
        guard !receipt.undoItems.isEmpty else { throw FinderBatchRenameError.noChanges }
        let currentKeys = Set(receipt.undoItems.map { normalizedPathKey($0.currentURL) })

        for item in receipt.undoItems {
            guard fileManager.fileExists(atPath: item.currentURL.path) else {
                throw FinderBatchRenameError.undoSourceMissing(item.currentURL.path)
            }
            guard try fileIdentity(at: item.currentURL) == item.identity else {
                throw FinderBatchRenameError.undoSourceChanged(item.currentURL.path)
            }
            if fileManager.fileExists(atPath: item.originalURL.path),
               !currentKeys.contains(normalizedPathKey(item.originalURL)) {
                throw FinderBatchRenameError.undoDestinationExists(item.originalURL.path)
            }
        }

        let reversePlan = FinderBatchRenamePlan(items: receipt.undoItems.map { item in
            FinderBatchRenamePlanItem(
                sourceURL: item.currentURL,
                destinationURL: item.originalURL,
                isDirectory: item.isDirectory
            )
        })
        let restored = try FinderBatchRenameExecutor(
            fileManager: fileManager,
            moveItem: moveItem
        ).execute(reversePlan).destinationURLs

        for (index, url) in restored.enumerated() {
            guard try fileIdentity(at: url) == receipt.undoItems[index].identity else {
                throw FinderBatchRenameError.executionFailed(L10n.string(.FinderActions.renameExecutionFileIdentityVerificationUndoFailed(String(describing: url.lastPathComponent))))
            }
        }
        return restored
    }

    private func fileIdentity(at url: URL) throws -> FinderFileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else {
            throw FinderBatchRenameError.undoSourceChanged(url.path)
        }
        return FinderFileIdentity(
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value
        )
    }

    private func normalizedPathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
