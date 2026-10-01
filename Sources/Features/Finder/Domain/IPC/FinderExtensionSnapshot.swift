import ArcKitPlatform
import Foundation

public struct FinderExtensionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 11

    public var schemaVersion: Int
    public var language: ArcKitLanguage
    public var createdAt: Date
    public var menuProfile: FinderMenuProfile
    public var fileTemplates: [FinderTemplateSnapshot]
    public var favoriteDirectories: [FinderFavoriteDirectorySnapshot]
    public var favoriteApplications: [FinderFavoriteApplicationSnapshot]
    public var availableTerminals: [TerminalApp]
    public var observedDirectoryPaths: [String]

    public init(
        schemaVersion: Int = FinderExtensionSnapshot.currentSchemaVersion,
        language: ArcKitLanguage = L10n.language,
        createdAt: Date = Date(),
        menuProfile: FinderMenuProfile = FinderMenuProfile(settings: .defaults),
        fileTemplates: [FinderTemplateSnapshot] = ConfigurableNewFileTemplate.defaults.map { FinderTemplateSnapshot(template: $0, isVisible: true) },
        favoriteDirectories: [FinderFavoriteDirectorySnapshot] = [],
        favoriteApplications: [FinderFavoriteApplicationSnapshot] = FavoriteApplication.defaults.map { FinderFavoriteApplicationSnapshot(application: $0, isVisible: true) },
        availableTerminals: [TerminalApp] = TerminalApp.allCases,
        observedDirectoryPaths: [String] = FinderObservedDirectoryBuilder.defaultObservedDirectoryPaths()
    ) {
        self.schemaVersion = schemaVersion
        self.language = language
        self.createdAt = createdAt
        self.menuProfile = menuProfile
        self.fileTemplates = fileTemplates
        self.favoriteDirectories = favoriteDirectories
        self.favoriteApplications = favoriteApplications
        self.availableTerminals = availableTerminals
        self.observedDirectoryPaths = observedDirectoryPaths
    }

    public static func make(
        settings: FinderRuntimeSettings,
        fileManager: FileManager = .default,
        applicationAvailability: (FavoriteApplication) -> Bool = { _ in true }
    ) -> FinderExtensionSnapshot {
        let configuration = settings.menuConfiguration
        let menuProfile = FinderMenuProfile(settings: settings)
        return FinderExtensionSnapshot(
            menuProfile: menuProfile,
            fileTemplates: configuration.fileTemplates.map { template in
                let reason = template.unsupportedReason
                return FinderTemplateSnapshot(template: template, isVisible: template.enabled && reason == nil, disabledReason: reason)
            },
            favoriteDirectories: configuration.favoriteDirectories.map { favorite in
                var isDirectory: ObjCBool = false
                let available = fileManager.fileExists(atPath: favorite.path, isDirectory: &isDirectory) && isDirectory.boolValue
                return FinderFavoriteDirectorySnapshot(
                    favorite: favorite,
                    isVisible: favorite.enabled && available,
                    disabledReason: available ? nil : L10n.string(.Finder.snapshotFolderMissingDisconnected),
                    children: FinderFavoriteDirectoryChildrenBuilder.children(for: favorite, fileManager: fileManager)
                )
            },
            favoriteApplications: configuration.favoriteApplications.map { application in
                let isAvailable = applicationAvailability(application)
                return FinderFavoriteApplicationSnapshot(
                    application: application,
                    isVisible: application.enabled && isAvailable,
                    disabledReason: isAvailable ? nil : L10n.string(.Finder.snapshotAppNotInstalled)
                )
            },
            availableTerminals: TerminalApp.allCases.filter { applicationAvailability($0.favoriteApplication) },
            observedDirectoryPaths: FinderObservedDirectoryBuilder.observedDirectoryPaths(settings: settings, fileManager: fileManager)
        )
    }

    public var runtimeSettings: FinderRuntimeSettings {
        var configuration = FinderMenuConfiguration(
            isEnabled: menuProfile.isEnabled,
            modules: menuProfile.modules,
            fileTemplates: fileTemplates.map(\.template),
            favoriteDirectories: favoriteDirectories.map(\.favorite),
            favoriteApplications: favoriteApplications.map(\.application),
            openNewFileAfterCreate: menuProfile.openNewFileAfterCreate,
            highRiskActionsEnabled: menuProfile.highRiskActionsEnabled,
            additionalObservedDirectoryPaths: menuProfile.additionalObservedDirectoryPaths
        )
        configuration.fileTemplates = fileTemplates.filter(\.isVisible).map(\.template)
        configuration.favoriteDirectories = favoriteDirectories.filter(\.isVisible).map(\.favorite)
        configuration.favoriteApplications = favoriteApplications.filter(\.isVisible).map(\.application)
        return FinderRuntimeSettings(
            defaultTerminal: menuProfile.defaultTerminal,
            menuConfiguration: configuration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, language, createdAt, menuProfile, fileTemplates, favoriteDirectories, favoriteApplications, availableTerminals, observedDirectoryPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: L10n.string(.Finder.snapshotSchemaMismatch)
            )
        }
        self.schemaVersion = schemaVersion
        language = try container.decode(ArcKitLanguage.self, forKey: .language)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        menuProfile = try container.decode(FinderMenuProfile.self, forKey: .menuProfile)
        fileTemplates = try container.decode([FinderTemplateSnapshot].self, forKey: .fileTemplates)
        favoriteDirectories = try container.decode([FinderFavoriteDirectorySnapshot].self, forKey: .favoriteDirectories)
        favoriteApplications = try container.decode([FinderFavoriteApplicationSnapshot].self, forKey: .favoriteApplications)
        availableTerminals = try container.decode([TerminalApp].self, forKey: .availableTerminals)
        let decodedPaths = try container.decode([String].self, forKey: .observedDirectoryPaths)
        observedDirectoryPaths = FinderObservedDirectoryBuilder.sanitizedObservedDirectoryPaths(
            decodedPaths,
            validationMode: .extensionRuntime
        )
        try Self.validateDecodedConfiguration(
            menuProfile: menuProfile,
            fileTemplates: fileTemplates,
            favoriteDirectories: favoriteDirectories,
            favoriteApplications: favoriteApplications,
            container: container
        )
        try Self.validateDecodedDirectoryChildren(favoriteDirectories, container: container)
    }

    private static func validateDecodedConfiguration(
        menuProfile: FinderMenuProfile,
        fileTemplates: [FinderTemplateSnapshot],
        favoriteDirectories: [FinderFavoriteDirectorySnapshot],
        favoriteApplications: [FinderFavoriteApplicationSnapshot],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        // Snapshot 自己不是设置文件，但它会直接驱动 Finder 进程；必须复用当前设置的严格解码门禁，
        // 拒绝缺失模块、重复 ID/路径和不安全目录，不能让损坏快照进入热路径后再碰运气。
        let configuration = FinderMenuConfiguration(
            isEnabled: menuProfile.isEnabled,
            modules: menuProfile.modules,
            fileTemplates: fileTemplates.map(\.template),
            favoriteDirectories: favoriteDirectories.map(\.favorite),
            favoriteApplications: favoriteApplications.map(\.application),
            openNewFileAfterCreate: menuProfile.openNewFileAfterCreate,
            highRiskActionsEnabled: menuProfile.highRiskActionsEnabled,
            additionalObservedDirectoryPaths: menuProfile.additionalObservedDirectoryPaths
        )
        do {
            let data = try JSONEncoder().encode(configuration)
            let decoded = try JSONDecoder().decode(FinderMenuConfiguration.self, from: data)
            guard decoded == configuration else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: L10n.string(.Finder.snapshotFinderExtensionSnapshotContainsData)
                ))
            }
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .menuProfile,
                in: container,
                debugDescription: L10n.string(.Finder.snapshotInvalidFinderExtensionSnapshotConfiguration(String(describing: error.localizedDescription)))
            )
        }
    }

    private static func validateDecodedDirectoryChildren(
        _ directories: [FinderFavoriteDirectorySnapshot],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        for directory in directories {
            guard directory.children.count <= 20 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favoriteDirectories,
                    in: container,
                    debugDescription: L10n.string(.Finder.snapshotChildLimit)
                )
            }
            let root = (directory.favorite.path as NSString).standardizingPath
            var childPaths: Set<String> = []
            for child in directory.children {
                let path = (child.path as NSString).standardizingPath
                let parent = (path as NSString).deletingLastPathComponent
                let fileName = (path as NSString).lastPathComponent
                guard parent == root else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .favoriteDirectories,
                        in: container,
                        debugDescription: L10n.string(.Finder.snapshotFavoriteFolderSnapshotChildrenDirect)
                    )
                }
                guard child.title == fileName, !fileName.hasPrefix(".") else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .favoriteDirectories,
                        in: container,
                        debugDescription: L10n.string(.Finder.snapshotFavoriteFolderChildTitlesMatchNon)
                    )
                }
                guard childPaths.insert(path).inserted else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .favoriteDirectories,
                        in: container,
                        debugDescription: L10n.string(.Finder.snapshotFavoriteFolderChildPathsUnique)
                    )
                }
            }
        }
    }
}
