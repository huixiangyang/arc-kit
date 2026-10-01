import ArcKitPlatform
import Foundation

public enum FinderBatchRenameMode: String, Codable, CaseIterable, Sendable {
    case replace
    case prefix
    case suffix
    case sequence

    public var displayName: String {
        switch self {
        case .replace: L10n.string(.Finder.renameFindReplace)
        case .prefix: L10n.string(.Finder.renameAddPrefix)
        case .suffix: L10n.string(.Finder.renameAddSuffix)
        case .sequence: L10n.string(.Finder.renameNumberSequentially)
        }
    }
}

public struct FinderBatchRenameRule: Codable, Equatable, Sendable {
    public var mode: FinderBatchRenameMode
    public var primaryText: String
    public var replacementText: String
    public var startNumber: Int
    public var minimumDigits: Int
    public var preserveFileExtension: Bool

    public init(
        mode: FinderBatchRenameMode,
        primaryText: String,
        replacementText: String = "",
        startNumber: Int = 1,
        minimumDigits: Int = 2,
        preserveFileExtension: Bool = true
    ) {
        self.mode = mode
        self.primaryText = primaryText
        self.replacementText = replacementText
        self.startNumber = startNumber
        self.minimumDigits = minimumDigits
        self.preserveFileExtension = preserveFileExtension
    }
}

public struct FinderBatchRenamePlanItem: Equatable, Sendable {
    public var sourceURL: URL
    public var destinationURL: URL
    public var isDirectory: Bool

    public init(sourceURL: URL, destinationURL: URL, isDirectory: Bool) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.isDirectory = isDirectory
    }

    public var changesName: Bool {
        sourceURL.path != destinationURL.path
    }
}

public struct FinderBatchRenamePlan: Equatable, Sendable {
    public var items: [FinderBatchRenamePlanItem]

    public init(items: [FinderBatchRenamePlanItem]) {
        self.items = items
    }

    public var changedItems: [FinderBatchRenamePlanItem] {
        items.filter(\.changesName)
    }
}

public struct FinderFileIdentity: Codable, Equatable, Sendable {
    public var systemNumber: UInt64
    public var fileNumber: UInt64

    public init(systemNumber: UInt64, fileNumber: UInt64) {
        self.systemNumber = systemNumber
        self.fileNumber = fileNumber
    }
}

public struct FinderBatchRenameUndoItem: Codable, Equatable, Sendable {
    public var currentURL: URL
    public var originalURL: URL
    public var isDirectory: Bool
    public var identity: FinderFileIdentity

    public init(currentURL: URL, originalURL: URL, isDirectory: Bool, identity: FinderFileIdentity) {
        self.currentURL = currentURL
        self.originalURL = originalURL
        self.isDirectory = isDirectory
        self.identity = identity
    }
}

public struct FinderBatchRenameExecutionReceipt: Codable, Equatable, Sendable {
    public var undoItems: [FinderBatchRenameUndoItem]

    public init(undoItems: [FinderBatchRenameUndoItem]) {
        self.undoItems = undoItems
    }

    public var destinationURLs: [URL] { undoItems.map(\.currentURL) }
}

public enum FinderBatchRenameError: LocalizedError, Equatable {
    case emptySelection
    case duplicateSource(String)
    case missingSource(String)
    case invalidRule(String)
    case invalidGeneratedName(String)
    case duplicateDestination(String)
    case destinationAlreadyExists(String)
    case noChanges
    case executionFailed(String)
    case rollbackFailed(original: String, rollback: String)
    case undoSourceMissing(String)
    case undoSourceChanged(String)
    case undoDestinationExists(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            L10n.string(.Finder.renameFinderSelectionRenameMissing)
        case let .duplicateSource(path):
            L10n.string(.Finder.transferDuplicateSelectedItem(String(describing: path)))
        case let .missingSource(path):
            L10n.string(.Finder.renameOriginalFileLongerExistsMissing(String(describing: path)))
        case let .invalidRule(reason):
            L10n.string(.Finder.renameInvalidRenameRule(String(describing: reason)))
        case let .invalidGeneratedName(name):
            L10n.string(.Finder.renameGeneratedInvalidFilename(String(describing: name.isEmpty ? L10n.string(.Finder.renameEmptyName) : name)))
        case let .duplicateDestination(path):
            L10n.string(.Finder.renameMultipleItemsReceiveSameName(String(describing: path)))
        case let .destinationAlreadyExists(path):
            L10n.string(.Finder.renameDestinationNameAlreadyExists(String(describing: path)))
        case .noChanges:
            L10n.string(.Finder.renameNoChanges)
        case let .executionFailed(reason):
            L10n.string(.Finder.renameBatchRenameOriginalNamesRestoredFailed(String(describing: reason)))
        case let .rollbackFailed(original, rollback):
            L10n.string(.Finder.renameBatchRenameOriginalNamesFailed(String(describing: original), String(describing: rollback)))
        case let .undoSourceMissing(path):
            L10n.string(.Finder.renameUndoItemMissing(String(describing: path)))
        case let .undoSourceChanged(path):
            L10n.string(.Finder.renameUndoItemReplaced(String(describing: path)))
        case let .undoDestinationExists(path):
            L10n.string(.Finder.renameUndoNameOccupied(String(describing: path)))
        }
    }
}

public struct FinderBatchRenamePlanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makePlan(sourcePaths: [String], rule: FinderBatchRenameRule) throws -> FinderBatchRenamePlan {
        guard !sourcePaths.isEmpty else { throw FinderBatchRenameError.emptySelection }
        try validate(rule)

        let sourceURLs = sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .sorted { lhs, rhs in
                let nameComparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                if nameComparison == .orderedSame { return lhs.path < rhs.path }
                return nameComparison == .orderedAscending
            }

        var sourceKeys: Set<String> = []
        var sourceKeyByURL: [URL: String] = [:]
        for url in sourceURLs {
            let key = normalizedPathKey(url)
            guard sourceKeys.insert(key).inserted else {
                throw FinderBatchRenameError.duplicateSource(url.path)
            }
            guard fileManager.fileExists(atPath: url.path) else {
                throw FinderBatchRenameError.missingSource(url.path)
            }
            sourceKeyByURL[url] = key
        }

        var destinationKeys: Set<String> = []
        var items: [FinderBatchRenamePlanItem] = []
        for (index, sourceURL) in sourceURLs.enumerated() {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw FinderBatchRenameError.missingSource(sourceURL.path)
            }
            let destinationName = try renamedName(
                sourceURL: sourceURL,
                isDirectory: isDirectory.boolValue,
                index: index,
                rule: rule
            )
            let destinationURL = sourceURL.deletingLastPathComponent()
                .appendingPathComponent(destinationName, isDirectory: isDirectory.boolValue)
                .standardizedFileURL
            let destinationKey = normalizedPathKey(destinationURL)
            guard destinationKeys.insert(destinationKey).inserted else {
                throw FinderBatchRenameError.duplicateDestination(destinationURL.path)
            }

            if fileManager.fileExists(atPath: destinationURL.path),
               !sourceKeys.contains(destinationKey),
               destinationKey != sourceKeyByURL[sourceURL] {
                throw FinderBatchRenameError.destinationAlreadyExists(destinationURL.path)
            }
            items.append(FinderBatchRenamePlanItem(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                isDirectory: isDirectory.boolValue
            ))
        }

        guard items.contains(where: \.changesName) else {
            throw FinderBatchRenameError.noChanges
        }
        return FinderBatchRenamePlan(items: items)
    }

    private func validate(_ rule: FinderBatchRenameRule) throws {
        switch rule.mode {
        case .replace:
            guard !rule.primaryText.isEmpty else {
                throw FinderBatchRenameError.invalidRule(L10n.string(.Finder.renameEmptySearch))
            }
        case .prefix, .suffix:
            guard !rule.primaryText.isEmpty else {
                throw FinderBatchRenameError.invalidRule(L10n.string(.Finder.renameEmptyAddition))
            }
        case .sequence:
            guard !rule.primaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FinderBatchRenameError.invalidRule(L10n.string(.Finder.renameEmptyBaseName))
            }
            guard rule.startNumber >= 0 else {
                throw FinderBatchRenameError.invalidRule(L10n.string(.Finder.renameNegativeStart))
            }
            guard (1 ... 6).contains(rule.minimumDigits) else {
                throw FinderBatchRenameError.invalidRule(L10n.string(.Finder.renameInvalidNumberWidth))
            }
        }
    }

    private func renamedName(
        sourceURL: URL,
        isDirectory: Bool,
        index: Int,
        rule: FinderBatchRenameRule
    ) throws -> String {
        let originalName = sourceURL.lastPathComponent
        let split = splitName(originalName, isDirectory: isDirectory, preserveExtension: rule.preserveFileExtension)
        let renamedStem: String
        switch rule.mode {
        case .replace:
            renamedStem = split.stem.replacingOccurrences(of: rule.primaryText, with: rule.replacementText)
        case .prefix:
            renamedStem = rule.primaryText + split.stem
        case .suffix:
            renamedStem = split.stem + rule.primaryText
        case .sequence:
            let number = rule.startNumber + index
            let formattedNumber = String(format: "%0*d", rule.minimumDigits, number)
            renamedStem = "\(rule.primaryText) \(formattedNumber)"
        }
        let result = renamedStem + split.extensionSuffix
        try validateGeneratedName(result)
        return result
    }

    private func splitName(_ name: String, isDirectory: Bool, preserveExtension: Bool) -> (stem: String, extensionSuffix: String) {
        guard preserveExtension, !isDirectory else { return (name, "") }
        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else { return (name, "") }
        return (url.deletingPathExtension().lastPathComponent, ".\(pathExtension)")
    }

    private func validateGeneratedName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              trimmed == name,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw FinderBatchRenameError.invalidGeneratedName(name)
        }
    }

    private func normalizedPathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
