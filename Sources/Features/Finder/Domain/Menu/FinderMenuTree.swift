import ArcKitPlatform
import Foundation

public struct FinderMenuDirectoryChild: Codable, Equatable, Sendable {
    public var title: String
    public var path: String

    public init(title: String, path: String) {
        self.title = title
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case title, path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decode(String.self, forKey: .path)
        guard title == title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: container, debugDescription: L10n.string(.Finder.menuTreeInvalidFavoriteFolderChildTitle))
        }
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: L10n.string(.Finder.menuTreeFavoriteFolderChildPathAbsolute))
        }
    }
}

public struct FinderMenuTreeState: Sendable {
    public var modules: [FinderMenuModuleConfiguration]
    public var fileTemplates: [ConfigurableNewFileTemplate]
    public var favoriteDirectories: [FavoriteDirectory]
    public var favoriteDirectoryChildren: [UUID: [FinderMenuDirectoryChild]]
    public var favoriteApplications: [FavoriteApplication]
    public var availableTerminals: [TerminalApp]
    public var defaultTerminal: TerminalApp
    public var highRiskActionsEnabled: Bool

    public init(
        modules: [FinderMenuModuleConfiguration],
        fileTemplates: [ConfigurableNewFileTemplate],
        favoriteDirectories: [FavoriteDirectory],
        favoriteDirectoryChildren: [UUID: [FinderMenuDirectoryChild]] = [:],
        favoriteApplications: [FavoriteApplication],
        availableTerminals: [TerminalApp] = TerminalApp.allCases,
        defaultTerminal: TerminalApp = .terminal,
        highRiskActionsEnabled: Bool
    ) {
        self.modules = modules
        self.fileTemplates = fileTemplates
        self.favoriteDirectories = favoriteDirectories
        self.favoriteDirectoryChildren = favoriteDirectoryChildren
        self.favoriteApplications = favoriteApplications
        self.availableTerminals = availableTerminals
        self.defaultTerminal = defaultTerminal
        self.highRiskActionsEnabled = highRiskActionsEnabled
    }

    public init(configuration: FinderMenuConfiguration) {
        self.init(
            modules: configuration.sortedEnabledModules,
            fileTemplates: configuration.enabledFileTemplates,
            favoriteDirectories: configuration.enabledFavoriteDirectories,
            favoriteApplications: configuration.enabledFavoriteApplications,
            highRiskActionsEnabled: configuration.highRiskActionsEnabled
        )
    }

    public init(settings: FinderRuntimeSettings) {
        self.init(
            modules: settings.menuConfiguration.sortedEnabledModules,
            fileTemplates: settings.menuConfiguration.enabledFileTemplates,
            favoriteDirectories: settings.menuConfiguration.enabledFavoriteDirectories,
            favoriteApplications: settings.menuConfiguration.enabledFavoriteApplications,
            defaultTerminal: settings.defaultTerminal,
            highRiskActionsEnabled: settings.menuConfiguration.highRiskActionsEnabled
        )
    }

    /// 从已完成可用性解析的扩展快照生成菜单树，供 Finder 运行时与主窗口预览共用。
    /// 这里保留常用目录子项，并过滤不可用模板、目录和 App，避免预览展示点击后必然失败的幽灵入口。
    public init(snapshot: FinderExtensionSnapshot) {
        let configuration = snapshot.runtimeSettings.menuConfiguration
        let visibleDirectories = snapshot.favoriteDirectories
            .filter { $0.isVisible && $0.favorite.enabled }
            .sorted {
                $0.favorite.sortOrder == $1.favorite.sortOrder
                    ? $0.favorite.name < $1.favorite.name
                    : $0.favorite.sortOrder < $1.favorite.sortOrder
            }
        let directoryChildren = visibleDirectories.reduce(into: [UUID: [FinderMenuDirectoryChild]]()) { result, item in
            // 解码层会拒绝重复 ID；这里仍使用覆盖赋值，避免任何内存构造数据触发 Dictionary fatalError。
            result[item.favorite.id] = item.children
        }
        self.init(
            modules: configuration.sortedEnabledModules,
            fileTemplates: snapshot.fileTemplates
                .filter { $0.isVisible && $0.template.enabled }
                .map(\.template)
                .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder },
            favoriteDirectories: visibleDirectories.map(\.favorite),
            favoriteDirectoryChildren: directoryChildren,
            favoriteApplications: snapshot.favoriteApplications
                .filter { $0.isVisible && $0.application.enabled }
                .map(\.application)
                .sorted { $0.sortOrder == $1.sortOrder ? $0.displayName < $1.displayName : $0.sortOrder < $1.sortOrder },
            availableTerminals: snapshot.availableTerminals,
            defaultTerminal: snapshot.menuProfile.defaultTerminal,
            highRiskActionsEnabled: configuration.highRiskActionsEnabled
        )
    }
}

public indirect enum FinderMenuEntry: Equatable, Sendable, Identifiable {
    case action(FinderActionDescriptor)
    case submenu(id: String, title: String, moduleID: FinderMenuModuleID?, icon: ArcIconName?, children: [FinderMenuEntry])
    case separator(id: String)

    public var id: String {
        switch self {
        case let .action(descriptor):
            descriptor.actionID
        case let .submenu(id, _, _, _, _), let .separator(id):
            id
        }
    }

    public var title: String {
        switch self {
        case let .action(descriptor):
            descriptor.title
        case let .submenu(_, title, _, _, _):
            title
        case .separator:
            ""
        }
    }
}
