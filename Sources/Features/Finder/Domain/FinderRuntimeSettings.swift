import ArcKitPlatform
import Foundation

public enum TerminalApp: String, CaseIterable, Codable, Sendable {
    case terminal
    case iTerm

    public var displayName: String {
        switch self {
        case .terminal:
            "Terminal"
        case .iTerm:
            "iTerm"
        }
    }
}

public extension TerminalApp {
    var bundleIdentifier: String {
        self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2"
    }

    init?(application: FavoriteApplication) {
        // 名称可由用户修改，不能用名称猜测终端并改变执行路由。
        guard let match = Self.allCases.first(where: { $0.bundleIdentifier == application.bundleIdentifier }) else { return nil }
        self = match
    }

    var favoriteApplication: FavoriteApplication {
        FavoriteApplication(displayName: displayName,
                            bundleIdentifier: bundleIdentifier,
                            sortOrder: 0)
    }
}

/// Finder 运行时的完整输入。Finder 业务只认识自己的配置，不能反向依赖应用级聚合设置。
public struct FinderRuntimeSettings: Codable, Equatable, Sendable {
    public var defaultTerminal: TerminalApp
    public var menuConfiguration: FinderMenuConfiguration

    public init(
        defaultTerminal: TerminalApp = .terminal,
        menuConfiguration: FinderMenuConfiguration = .defaults
    ) {
        self.defaultTerminal = defaultTerminal
        self.menuConfiguration = menuConfiguration
    }

    public static let defaults = FinderRuntimeSettings()
}

public extension FinderRuntimeSettings {
    static let recordLayout = ArcKitRecordLayout("finder_preferences", fields: ["defaultTerminal", "menuConfiguration.isEnabled", "menuConfiguration.openNewFileAfterCreate", "menuConfiguration.highRiskActionsEnabled", "menuConfiguration.additionalObservedDirectoryPaths"], json: ["menuConfiguration.additionalObservedDirectoryPaths"], children: [
        "menuConfiguration.modules": ArcKitRecordLayout("finder_modules", fields: ["moduleID", "enabled", "sortOrder"]),
        "menuConfiguration.fileTemplates": ArcKitRecordLayout("file_templates", fields: ["id", "displayName", "fileExtension", "enabled", "sortOrder", "isPinnedToRootMenu", "openAfterCreate", "templateSource", "originalFileName", "preferredBundleIDs"], json: ["templateSource", "preferredBundleIDs"]),
        "menuConfiguration.favoriteDirectories": ArcKitRecordLayout("favorite_directories", fields: ["id", "name", "path", "enabled", "sortOrder", "displayMode"]),
        "menuConfiguration.favoriteApplications": ArcKitRecordLayout("favorite_applications", fields: ["id", "displayName", "bundleIdentifier", "appPath", "enabled", "sortOrder", "isPinnedToRootMenu"])
    ])
}
