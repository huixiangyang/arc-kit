import ArcKitFinder
import ArcKitPlatform
import ArcKitMouse
import ArcKitWindow
import Foundation

public enum ArcAppearance: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case dark
    case light

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: L10n.string(.Common.languageSystem)
        case .dark: L10n.string(.Common.dark)
        case .light: L10n.string(.Common.light)
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 24

    public var schemaVersion: Int
    public var language: ArcKitLanguage
    public var appearance: ArcAppearance
    /// 独立于系统辅助功能设置，关闭 Arc Kit 内非必要的界面动画。
    public var reduceMotionEnabled: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool
    public var mouseEnhancement: MouseEnhancementSettings
    public var windowManagement: WindowManagementSettings
    public var launchAtLoginEnabled: Bool
    public var finder: FinderRuntimeSettings

    public init(
        schemaVersion: Int = AppSettings.schemaVersion,
        language: ArcKitLanguage = .system,
        appearance: ArcAppearance = .system,
        reduceMotionEnabled: Bool = false,
        showDockIcon: Bool = true,
        showMenuBarIcon: Bool = true,
        mouseEnhancement: MouseEnhancementSettings = .defaults,
        windowManagement: WindowManagementSettings = .defaults,
        launchAtLoginEnabled: Bool = true,
        finder: FinderRuntimeSettings = .defaults
    ) {
        self.schemaVersion = schemaVersion
        self.language = language
        self.appearance = appearance
        self.reduceMotionEnabled = reduceMotionEnabled
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
        self.mouseEnhancement = mouseEnhancement
        self.windowManagement = windowManagement
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.finder = finder
    }

    public static let defaults = AppSettings()

    public var enabledFinderMenuCount: Int {
        guard finder.menuConfiguration.isEnabled else { return 0 }
        return finder.menuConfiguration.sortedEnabledModules.count
    }

    public var finderMenuSummary: String {
        guard finder.menuConfiguration.isEnabled else { return L10n.string(.Common.off) }
        return L10n.string(.Settings.configurationEnabled(String(describing: enabledFinderMenuCount), String(describing: finder.menuConfiguration.modules.count)))
    }
}

public extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case showDockIcon
        case showMenuBarIcon
        case schemaVersion
        case language
        case appearance
        case reduceMotionEnabled
        case mouseEnhancement
        case windowManagement
        case launchAtLoginEnabled
        case finder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard decodedSchemaVersion == AppSettings.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: L10n.string(.Settings.configurationSchemaMismatch))
        }
        do {
            schemaVersion = decodedSchemaVersion
            language = try container.decode(ArcKitLanguage.self, forKey: .language)
            appearance = try container.decode(ArcAppearance.self, forKey: .appearance)
            reduceMotionEnabled = try container.decode(Bool.self, forKey: .reduceMotionEnabled)
            showDockIcon = try container.decode(Bool.self, forKey: .showDockIcon)
            showMenuBarIcon = try container.decode(Bool.self, forKey: .showMenuBarIcon)
            mouseEnhancement = try container.decode(MouseEnhancementSettings.self, forKey: .mouseEnhancement)
            windowManagement = try container.decode(WindowManagementSettings.self, forKey: .windowManagement)
            launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
            finder = try container.decode(FinderRuntimeSettings.self, forKey: .finder)
        } catch {
            throw error
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(language, forKey: .language)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(reduceMotionEnabled, forKey: .reduceMotionEnabled)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(mouseEnhancement, forKey: .mouseEnhancement)
        try container.encode(windowManagement, forKey: .windowManagement)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(finder, forKey: .finder)
    }
}
