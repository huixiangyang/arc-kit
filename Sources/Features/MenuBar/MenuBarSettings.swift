import ArcKitPlatform
import Foundation

/// 只持久化用户意图；实际展开状态和 AX 观测身份不进入数据库。
public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var shelfShortcut: MenuBarShortcutPreset
    public var revealShortcut: MenuBarShortcutPreset
    public var isEnabled: Bool
    public var deepSectionEnabled: Bool
    public var style: MenuBarAppearanceStyle
    public var opacity: Double
    public var cornerRadius: Double

    public static let defaults = MenuBarSettings()

    public init(isEnabled: Bool = false, deepSectionEnabled: Bool = false,
                style: MenuBarAppearanceStyle = .split, opacity: Double = 0.72, cornerRadius: Double = 9,
                shelfShortcut: MenuBarShortcutPreset = .disabled, revealShortcut: MenuBarShortcutPreset = .disabled) {
        self.shelfShortcut = shelfShortcut
        self.revealShortcut = revealShortcut
        self.isEnabled = isEnabled
        self.deepSectionEnabled = deepSectionEnabled
        self.style = style
        self.opacity = opacity
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, deepSectionEnabled, style, opacity, cornerRadius, shelfShortcut, revealShortcut }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shelfShortcut = try container.decode(MenuBarShortcutPreset.self, forKey: .shelfShortcut)
        revealShortcut = try container.decode(MenuBarShortcutPreset.self, forKey: .revealShortcut)
        guard shelfShortcut == .disabled || shelfShortcut != revealShortcut else {
            throw DecodingError.dataCorruptedError(forKey: .shelfShortcut, in: container, debugDescription: L10n.string(.MenuBar.hotKeyDuplicate))
        }
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        deepSectionEnabled = try container.decode(Bool.self, forKey: .deepSectionEnabled)
        style = try container.decode(MenuBarAppearanceStyle.self, forKey: .style)
        opacity = try container.decode(Double.self, forKey: .opacity)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        guard opacity.isFinite, (0.3...1).contains(opacity), cornerRadius.isFinite, (0...16).contains(cornerRadius) else {
            throw DecodingError.dataCorruptedError(forKey: .opacity, in: container,
                debugDescription: L10n.string(.MenuBar.settingsInvalid))
        }
    }

    static let recordLayout = ArcKitRecordLayout("menu_bar_preferences", fields: ["isEnabled", "deepSectionEnabled", "style", "opacity", "cornerRadius", "shelfShortcut", "revealShortcut"])
}

enum MenuBarPresentation: String, CaseIterable, Identifiable, Sendable {
    case collapsed, expanded, all
    var id: Self { self }
    var title: String {
        switch self {
        case .collapsed: L10n.string(.MenuBar.actionCollapse)
        case .expanded: L10n.string(.MenuBar.actionExpand)
        case .all: L10n.string(.MenuBar.actionShowAllShort)
        }
    }
}
