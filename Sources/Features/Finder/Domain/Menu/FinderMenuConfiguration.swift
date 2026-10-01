import ArcKitPlatform
import Foundation

/// Finder 右键菜单完整配置。
public struct FinderMenuConfiguration: Codable, Equatable, Sendable {
    /// Finder 右键菜单总开关。关闭后扩展仍可加载，但不会向 Finder 提供 Arc Kit 菜单。
    public var isEnabled: Bool
    public var modules: [FinderMenuModuleConfiguration]
    public var fileTemplates: [ConfigurableNewFileTemplate]
    public var favoriteDirectories: [FavoriteDirectory]
    public var favoriteApplications: [FavoriteApplication]
    public var openNewFileAfterCreate: Bool
    public var highRiskActionsEnabled: Bool
    /// 用户 Home 之外，由用户明确加入的外置卷或普通工作目录。
    public var additionalObservedDirectoryPaths: [String]

    public init(
        isEnabled: Bool = true,
        modules: [FinderMenuModuleConfiguration] = FinderMenuConfiguration.defaultModules,
        fileTemplates: [ConfigurableNewFileTemplate] = ConfigurableNewFileTemplate.defaults,
        favoriteDirectories: [FavoriteDirectory] = [],
        favoriteApplications: [FavoriteApplication] = FavoriteApplication.defaults,
        openNewFileAfterCreate: Bool = false,
        highRiskActionsEnabled: Bool = false,
        additionalObservedDirectoryPaths: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.modules = modules
        self.fileTemplates = fileTemplates
        self.favoriteDirectories = favoriteDirectories
        self.favoriteApplications = favoriteApplications
        self.openNewFileAfterCreate = openNewFileAfterCreate
        self.highRiskActionsEnabled = highRiskActionsEnabled
        self.additionalObservedDirectoryPaths = additionalObservedDirectoryPaths
    }

    public static let defaults = FinderMenuConfiguration()

    public static let defaultModules: [FinderMenuModuleConfiguration] = FinderMenuModuleID.allCases
        .sorted { $0.defaultOrder == $1.defaultOrder ? $0.rawValue < $1.rawValue : $0.defaultOrder < $1.defaultOrder }
        .enumerated().map { index, moduleID in
            FinderMenuModuleConfiguration(moduleID: moduleID, sortOrder: index)
        }

    public func module(_ moduleID: FinderMenuModuleID) -> FinderMenuModuleConfiguration {
        modules.first { $0.moduleID == moduleID }
            ?? FinderMenuModuleConfiguration(moduleID: moduleID, sortOrder: moduleID.defaultOrder)
    }

    public var sortedEnabledModules: [FinderMenuModuleConfiguration] {
        modules.filter(\.isEnabled)
            .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
    }

    public var enabledFileTemplates: [ConfigurableNewFileTemplate] {
        fileTemplates
            .filter { $0.enabled && $0.isFinderNewFileSupported }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
    }

    public var enabledFavoriteDirectories: [FavoriteDirectory] {
        favoriteDirectories.filter(\.enabled).sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }

    public var enabledFavoriteApplications: [FavoriteApplication] {
        favoriteApplications.filter(\.enabled).sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
    }

    public mutating func sortAndNormalizeOrders() {
        modules.sort { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
        fileTemplates.sort { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
        favoriteDirectories.sort { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
        favoriteApplications.sort { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder }
        normalizeOrdersPreservingCurrentOrder()
    }

    public mutating func normalizeOrdersPreservingCurrentOrder() {
        for index in modules.indices {
            modules[index].sortOrder = index
        }
        for index in fileTemplates.indices {
            fileTemplates[index].sortOrder = index
        }
        for index in favoriteDirectories.indices {
            favoriteDirectories[index].sortOrder = index
        }
        for index in favoriteApplications.indices {
            favoriteApplications[index].sortOrder = index
        }
    }

    public mutating func moveModuleInDisplayOrder(from index: Int, offset: Int) {
        sortAndNormalizeOrders()
        let target = index + offset
        guard modules.indices.contains(index), modules.indices.contains(target) else { return }
        modules.swapAt(index, target)
        normalizeOrdersPreservingCurrentOrder()
    }

    public mutating func moveTemplateInDisplayOrder(from index: Int, offset: Int) {
        sortAndNormalizeOrders()
        let target = index + offset
        guard fileTemplates.indices.contains(index), fileTemplates.indices.contains(target) else { return }
        fileTemplates.swapAt(index, target)
        normalizeOrdersPreservingCurrentOrder()
    }

    public mutating func moveFavoriteDirectoryInDisplayOrder(from index: Int, offset: Int) {
        sortAndNormalizeOrders()
        let target = index + offset
        guard favoriteDirectories.indices.contains(index), favoriteDirectories.indices.contains(target) else { return }
        favoriteDirectories.swapAt(index, target)
        normalizeOrdersPreservingCurrentOrder()
    }

    public mutating func moveFavoriteApplicationInDisplayOrder(from index: Int, offset: Int) {
        sortAndNormalizeOrders()
        let target = index + offset
        guard favoriteApplications.indices.contains(index), favoriteApplications.indices.contains(target) else { return }
        favoriteApplications.swapAt(index, target)
        normalizeOrdersPreservingCurrentOrder()
    }

    /// 只在当前真正可见的应用之间移动，避免隐藏的未安装应用吞掉一次上移或下移操作。
    public mutating func moveFavoriteApplicationInVisibleOrder(
        id: UUID,
        offset: Int,
        visibleApplicationIDs: Set<UUID>
    ) {
        sortAndNormalizeOrders()
        let visibleIndices = favoriteApplications.indices.filter {
            visibleApplicationIDs.contains(favoriteApplications[$0].id)
        }
        guard let sourcePosition = visibleIndices.firstIndex(where: { favoriteApplications[$0].id == id }) else {
            return
        }
        let targetPosition = sourcePosition + offset
        guard visibleIndices.indices.contains(targetPosition) else { return }
        favoriteApplications.swapAt(visibleIndices[sourcePosition], visibleIndices[targetPosition])
        normalizeOrdersPreservingCurrentOrder()
    }
}

extension FinderMenuConfiguration {
    enum CodingKeys: String, CodingKey {
        case isEnabled, modules, fileTemplates, favoriteDirectories, favoriteApplications,
             openNewFileAfterCreate, highRiskActionsEnabled, additionalObservedDirectoryPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let decodedModules = try container.decode([FinderMenuModuleConfiguration].self, forKey: .modules)
        try Self.validateDecodedModules(decodedModules, container: container)
        modules = decodedModules
        let decodedFileTemplates = try container.decode([ConfigurableNewFileTemplate].self, forKey: .fileTemplates)
        try Self.validateDecodedFileTemplates(decodedFileTemplates, container: container)
        fileTemplates = decodedFileTemplates
        let decodedFavoriteDirectories = try container.decode([FavoriteDirectory].self, forKey: .favoriteDirectories)
        try Self.validateDecodedFavoriteDirectories(decodedFavoriteDirectories, container: container)
        favoriteDirectories = decodedFavoriteDirectories
        let decodedFavoriteApplications = try container.decode([FavoriteApplication].self, forKey: .favoriteApplications)
        try Self.validateDecodedFavoriteApplications(decodedFavoriteApplications, container: container)
        favoriteApplications = decodedFavoriteApplications
        openNewFileAfterCreate = try container.decode(Bool.self, forKey: .openNewFileAfterCreate)
        highRiskActionsEnabled = try container.decode(Bool.self, forKey: .highRiskActionsEnabled)
        let decodedAdditionalPaths = try container.decode([String].self, forKey: .additionalObservedDirectoryPaths)
        additionalObservedDirectoryPaths = try Self.canonicalDecodedAdditionalObservedDirectoryPaths(
            decodedAdditionalPaths,
            container: container
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(modules, forKey: .modules)
        try container.encode(fileTemplates, forKey: .fileTemplates)
        try container.encode(favoriteDirectories, forKey: .favoriteDirectories)
        try container.encode(favoriteApplications, forKey: .favoriteApplications)
        try container.encode(openNewFileAfterCreate, forKey: .openNewFileAfterCreate)
        try container.encode(highRiskActionsEnabled, forKey: .highRiskActionsEnabled)
        try container.encode(additionalObservedDirectoryPaths, forKey: .additionalObservedDirectoryPaths)
    }

    private static func validateDecodedModules(
        _ modules: [FinderMenuModuleConfiguration],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let moduleIDs = modules.map(\.moduleID)
        let moduleIDSet = Set(moduleIDs)
        let expected = Set(FinderMenuModuleID.allCases)
        guard moduleIDSet == expected, moduleIDs.count == expected.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .modules,
                in: container,
                debugDescription: L10n.string(.Finder.menuValidationIncompleteModules)
            )
        }
    }

    private static func validateDecodedFileTemplates(
        _ templates: [ConfigurableNewFileTemplate],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        var ids: Set<String> = []
        for template in templates {
            guard ids.insert(template.id).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fileTemplates,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationNewFileTemplateIdsUnique)
                )
            }
        }
    }

    private static func validateDecodedFavoriteDirectories(
        _ directories: [FavoriteDirectory],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        var ids: Set<UUID> = []
        var paths: Set<String> = []
        for directory in directories {
            guard ids.insert(directory.id).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favoriteDirectories,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationFavoriteFolderIdsUnique)
                )
            }
            guard paths.insert((directory.path as NSString).standardizingPath).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favoriteDirectories,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationFavoriteFolderPathsUnique)
                )
            }
        }
    }

    private static func validateDecodedFavoriteApplications(
        _ applications: [FavoriteApplication],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        var ids: Set<UUID> = []
        var keys: Set<String> = []
        for application in applications {
            guard ids.insert(application.id).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favoriteApplications,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationFavoriteAppIdsUnique)
                )
            }
            let uniqueKey = application.bundleIdentifier ?? application.appPath ?? "-"
            guard keys.insert(uniqueKey).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .favoriteApplications,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationFavoriteAppBundleIDsPaths)
                )
            }
        }
    }

    private static func canonicalDecodedAdditionalObservedDirectoryPaths(
        _ paths: [String],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String] {
        var standardizedPaths: Set<String> = []
        var canonicalPaths: [String] = []
        let home = (FinderUserHomeDirectoryResolver.resolve().path as NSString).standardizingPath
        for path in paths {
            guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .additionalObservedDirectoryPaths,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationEmptyDirectory)
                )
            }
            guard path.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .additionalObservedDirectoryPaths,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationRelativeDirectory)
                )
            }
            let standardizedPath = (path as NSString).standardizingPath
            // Home 与 iCloud Drive 均由默认根管理，不在附加目录中重复保存。
            if standardizedPath == home || standardizedPath.hasPrefix("\(home)/") {
                continue
            }
            guard FinderObservedDirectoryBuilder.isSafeObservedDirectoryPath(standardizedPath) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .additionalObservedDirectoryPaths,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationProtectedDirectory)
                )
            }
            guard standardizedPaths.insert(standardizedPath).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .additionalObservedDirectoryPaths,
                    in: container,
                    debugDescription: L10n.string(.Finder.menuValidationAdditionalWatchedDirectoriesUnique)
                )
            }
            canonicalPaths.append(standardizedPath)
        }
        return canonicalPaths
    }
}
