import ArcKitPlatform
import Foundation

/// 常用应用程序。
public struct FavoriteApplication: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var bundleIdentifier: String?
    public var appPath: String?
    public var enabled: Bool
    public var sortOrder: Int
    public var isPinnedToRootMenu: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        appPath: String? = nil,
        enabled: Bool = true,
        sortOrder: Int,
        isPinnedToRootMenu: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.isPinnedToRootMenu = isPinnedToRootMenu
    }

    /// 默认预设的常用开发工具 App 列表。
    public var localizedDisplayName: String {
        if bundleIdentifier == "com.apple.Finder", ["访达", "Finder"].contains(displayName) { // i18n-ignore: 内置名称识别，用户改名保留
            return L10n.string(.Finder.appFinder)
        }
        return displayName
    }

    public static let defaults: [FavoriteApplication] = [
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, displayName: "Finder", bundleIdentifier: "com.apple.Finder", sortOrder: 0),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!, displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", sortOrder: 1),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!, displayName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", sortOrder: 2),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!, displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", sortOrder: 3),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!, displayName: "Sublime Text", bundleIdentifier: "com.sublimetext.4", sortOrder: 4),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!, displayName: "Chrome", bundleIdentifier: "com.google.Chrome", sortOrder: 5),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000109")!, displayName: "Safari", bundleIdentifier: "com.apple.Safari", sortOrder: 6),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!, displayName: "Figma", bundleIdentifier: "com.figma.Desktop", sortOrder: 7),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!, displayName: "Typora", bundleIdentifier: "abnerworks.Typora", sortOrder: 8),
        FavoriteApplication(id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!, displayName: "SourceTree", bundleIdentifier: "com.torusknot.SourceTreeDesktop", sortOrder: 9),
    ]
}

extension FavoriteApplication {
    enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, appPath, enabled, sortOrder, isPinnedToRootMenu
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try Self.decodeStrictNonEmptyString(container, forKey: .displayName, fieldName: L10n.string(.Finder.appFavoriteAppName))
        bundleIdentifier = try Self.decodeStrictOptionalString(container, forKey: .bundleIdentifier, fieldName: L10n.string(.Finder.appFavoriteAppBundleidentifier))
        appPath = try Self.decodeStrictOptionalString(container, forKey: .appPath, fieldName: L10n.string(.Finder.appFavoriteAppPath))
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        isPinnedToRootMenu = try container.decode(Bool.self, forKey: .isPinnedToRootMenu)

        guard bundleIdentifier != nil || appPath != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifier,
                in: container,
                debugDescription: L10n.string(.Finder.appFavoriteAppsRequireLeastBundleidentifier)
            )
        }
        if let appPath {
            guard appPath.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .appPath,
                    in: container,
                    debugDescription: L10n.string(.Finder.appFavoriteAppPathAbsolute)
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(appPath, forKey: .appPath)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(isPinnedToRootMenu, forKey: .isPinnedToRootMenu)
    }

    private static func decodeStrictNonEmptyString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fieldName: String
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: L10n.string(.Finder.actionInvalidName(String(describing: fieldName)))
            )
        }
        return value
    }

    private static func decodeStrictOptionalString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fieldName: String
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: L10n.string(.Finder.actionInvalidName(String(describing: fieldName)))
            )
        }
        return value
    }
}
