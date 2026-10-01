import ArcKitPlatform
import Foundation

public enum FinderFileTransferMode: String, Equatable, Sendable {
    case copy
    case move

    public var actionTitle: String {
        switch self {
        case .copy: L10n.string(.Finder.transferCopy)
        case .move: L10n.string(.Finder.transferMove)
        }
    }
}

public struct FinderFileTransferPlanItem: Equatable, Sendable {
    public var sourceURL: URL
    public var destinationURL: URL
    public var isDirectory: Bool

    public init(sourceURL: URL, destinationURL: URL, isDirectory: Bool) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.isDirectory = isDirectory
    }
}

public struct FinderFileTransferPlan: Equatable, Sendable {
    public var mode: FinderFileTransferMode
    public var destinationDirectory: URL
    public var items: [FinderFileTransferPlanItem]

    public init(
        mode: FinderFileTransferMode,
        destinationDirectory: URL,
        items: [FinderFileTransferPlanItem]
    ) {
        self.mode = mode
        self.destinationDirectory = destinationDirectory
        self.items = items
    }
}

public enum FinderFileTransferError: LocalizedError, Equatable {
    case emptySelection
    case missingSource(String)
    case duplicateSource(String)
    case invalidDestination(String)
    case sourceAlreadyInDestination(String)
    case destinationInsideSource(source: String, destination: String)
    case executionFailed(action: String, reason: String)
    case rollbackFailed(action: String, original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            L10n.string(.Finder.transferFinderSelectionTransferMissing)
        case let .missingSource(path):
            L10n.string(.Finder.transferSourceItemLongerExistsMissing(String(describing: path)))
        case let .duplicateSource(path):
            L10n.string(.Finder.transferDuplicateSelectedItem(String(describing: path)))
        case let .invalidDestination(path):
            L10n.string(.Finder.transferInvalidDestination(String(describing: path)))
        case let .sourceAlreadyInDestination(path):
            L10n.string(.Finder.transferItemAlreadyDestination(String(describing: path)))
        case let .destinationInsideSource(source, destination):
            L10n.string(.Finder.transferRecursiveDestination(String(describing: source), String(describing: destination)))
        case let .executionFailed(action, reason):
            L10n.string(.Finder.transferProcessedItemsRestoredFailed(String(describing: action), String(describing: reason)))
        case let .rollbackFailed(action, original, rollback):
            L10n.string(.Finder.transferRollbackFailed(String(describing: action), String(describing: original), String(describing: rollback)))
        }
    }
}

public struct FinderFileTransferPlanner {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makePlan(
        sourcePaths: [String],
        destinationDirectoryPath: String,
        mode: FinderFileTransferMode
    ) throws -> FinderFileTransferPlan {
        guard !sourcePaths.isEmpty else { throw FinderFileTransferError.emptySelection }

        let destinationDirectory = URL(fileURLWithPath: destinationDirectoryPath, isDirectory: true)
            .standardizedFileURL
        var isDestinationDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDestinationDirectory),
              isDestinationDirectory.boolValue
        else {
            throw FinderFileTransferError.invalidDestination(destinationDirectory.path)
        }

        let destinationKey = normalizedPathKey(destinationDirectory)
        var sourceKeys: Set<String> = []
        var reservedDestinationKeys: Set<String> = []
        var items: [FinderFileTransferPlanItem] = []

        for path in sourcePaths {
            let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
            let sourceKey = normalizedPathKey(sourceURL)
            guard sourceKeys.insert(sourceKey).inserted else {
                throw FinderFileTransferError.duplicateSource(sourceURL.path)
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else {
                throw FinderFileTransferError.missingSource(sourceURL.path)
            }
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            guard normalizedPathKey(sourceURL.deletingLastPathComponent()) != destinationKey else {
                throw FinderFileTransferError.sourceAlreadyInDestination(sourceURL.path)
            }
            if isDirectory, destinationKey == sourceKey || isDescendant(destinationDirectory, of: sourceURL) {
                throw FinderFileTransferError.destinationInsideSource(
                    source: sourceURL.path,
                    destination: destinationDirectory.path
                )
            }

            let destinationURL = uniqueDestinationURL(
                for: sourceURL,
                in: destinationDirectory,
                reservedKeys: &reservedDestinationKeys
            )
            items.append(FinderFileTransferPlanItem(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                isDirectory: isDirectory
            ))
        }

        return FinderFileTransferPlan(
            mode: mode,
            destinationDirectory: destinationDirectory,
            items: items
        )
    }

    private func uniqueDestinationURL(
        for sourceURL: URL,
        in directory: URL,
        reservedKeys: inout Set<String>
    ) -> URL {
        let original = directory.appendingPathComponent(sourceURL.lastPathComponent)
        if isAvailable(original, reservedKeys: reservedKeys) {
            reservedKeys.insert(normalizedPathKey(original))
            return original
        }

        let ext = sourceURL.pathExtension
        let base = sourceURL.deletingPathExtension().lastPathComponent
        for index in 2 ..< 10_000 {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if isAvailable(candidate, reservedKeys: reservedKeys) {
                reservedKeys.insert(normalizedPathKey(candidate))
                return candidate
            }
        }

        let fallback = directory.appendingPathComponent("\(base) \(UUID().uuidString)")
            .appendingPathExtension(ext)
        reservedKeys.insert(normalizedPathKey(fallback))
        return fallback
    }

    private func isAvailable(_ url: URL, reservedKeys: Set<String>) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) == nil && !reservedKeys.contains(normalizedPathKey(url))
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let directoryPath = normalizedPathKey(directory)
        let candidatePath = normalizedPathKey(candidate)
        return candidatePath.hasPrefix(directoryPath + "/")
    }

    private func normalizedPathKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
