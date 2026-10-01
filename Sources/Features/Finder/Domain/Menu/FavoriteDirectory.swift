import ArcKitPlatform
import Foundation

/// 常用目录。
public struct FavoriteDirectory: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var enabled: Bool
    public var sortOrder: Int
    public var displayMode: FavoriteDirectoryDisplayMode

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        enabled: Bool = true,
        sortOrder: Int = 0,
        displayMode: FavoriteDirectoryDisplayMode = .submenuOnly
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.displayMode = displayMode
    }
}

extension FavoriteDirectory {
    enum CodingKeys: String, CodingKey {
        case id, name, path, enabled, sortOrder, displayMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        displayMode = try container.decode(FavoriteDirectoryDisplayMode.self, forKey: .displayMode)

        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: L10n.string(.Finder.directoryInvalidName)
            )
        }
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: L10n.string(.Finder.directoryInvalidPath)
            )
        }
        guard path.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: L10n.string(.Finder.directoryFavoriteFolderPathAbsolute)
            )
        }
    }
}

/// 常用目录子菜单展示模式。
public enum FavoriteDirectoryDisplayMode: String, Codable, Sendable, CaseIterable {
    case submenuOnly
    case showChildDirectories
    case showChildItems

    public var title: String {
        switch self {
        case .submenuOnly:          L10n.string(.Finder.directoryFolder)
        case .showChildDirectories: L10n.string(.Finder.directoryIncludeSubfolders)
        case .showChildItems:       L10n.string(.Finder.directoryIncludeFilesSubfolders)
        }
    }
}

public enum FinderFavoriteDirectoryChildrenBuilder {
    public static func children(
        for favorite: FavoriteDirectory,
        fileManager: FileManager = .default,
        limit: Int = 20
    ) -> [FinderMenuDirectoryChild] {
        guard favorite.enabled, favorite.displayMode != .submenuOnly, limit > 0 else { return [] }
        let directoryURL = URL(fileURLWithPath: favorite.path, isDirectory: true)
        guard let childURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return childURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { childURL -> FinderMenuDirectoryChild? in
                if favorite.displayMode == .showChildDirectories {
                    guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
                }
                return FinderMenuDirectoryChild(title: childURL.lastPathComponent, path: childURL.standardizedFileURL.path)
            }
            .prefix(limit)
            .map { $0 }
    }
}
