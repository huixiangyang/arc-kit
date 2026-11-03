import ArcKitPlatform
import Foundation

/// 只持久化用户意图；实际展开状态和 AX 观测身份不进入数据库。
public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var shelfShortcut: HotKeyChord
    public var revealShortcut: HotKeyChord
    public var toggleShortcut: HotKeyChord
    public var shortcutsEnabled: Bool
    public var collectedApplications: Set<String>
    public var isEnabled: Bool
    public var deepSectionEnabled: Bool
    public var style: MenuBarAppearanceStyle
    public var opacity: Double
    public var cornerRadius: Double

    public static let defaults = MenuBarSettings()

    public init(isEnabled: Bool = false, deepSectionEnabled: Bool = false,
                style: MenuBarAppearanceStyle = .split, opacity: Double = 0.72, cornerRadius: Double = 9,
                shelfShortcut: HotKeyChord = .disabled, revealShortcut: HotKeyChord = .disabled,
                toggleShortcut: HotKeyChord = .disabled, shortcutsEnabled: Bool = false, collectedApplications: Set<String> = []) {
        self.shelfShortcut = shelfShortcut
        self.revealShortcut = revealShortcut
        self.toggleShortcut = toggleShortcut
        self.shortcutsEnabled = shortcutsEnabled
        self.collectedApplications = collectedApplications
        self.isEnabled = isEnabled
        self.deepSectionEnabled = deepSectionEnabled
        self.style = style
        self.opacity = opacity
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey { case collectedApplications, isEnabled, deepSectionEnabled, style, opacity, cornerRadius, shelfShortcut, revealShortcut, toggleShortcut, shortcutsEnabled }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shelfShortcut = try container.decode(HotKeyChord.self, forKey: .shelfShortcut)
        revealShortcut = try container.decode(HotKeyChord.self, forKey: .revealShortcut)
        toggleShortcut = try container.decode(HotKeyChord.self, forKey: .toggleShortcut)
        shortcutsEnabled = try container.decode(Bool.self, forKey: .shortcutsEnabled)
        let shortcuts = [shelfShortcut, revealShortcut, toggleShortcut].filter(\.isEnabled)
        guard Set(shortcuts.map(\.shortcutIdentifier)).count == shortcuts.count else {
            throw DecodingError.dataCorruptedError(forKey: .shelfShortcut, in: container, debugDescription: L10n.string(.MenuBar.hotKeyDuplicate))
        }
        collectedApplications = try container.decode(Set<String>.self, forKey: .collectedApplications)
        guard collectedApplications.allSatisfy({ !$0.isEmpty && !$0.contains("::") }) else {
            throw DecodingError.dataCorruptedError(forKey: .collectedApplications, in: container, debugDescription: L10n.string(.MenuBar.settingsInvalid))
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

    /// 关闭收纳只撤销需要分隔线的动作，搜索快捷键可单独使用。
    var activeShortcuts: [MenuBarHotKeyAction: HotKeyChord] {
        guard shortcutsEnabled else { return [:] }
        return Dictionary(uniqueKeysWithValues: MenuBarHotKeyAction.allCases.compactMap { action in
            let chord = self[keyPath: action.keyPath]
            return chord.isEnabled && (!action.requiresCollection || isEnabled) ? (action, chord) : nil
        })
    }

    static let recordLayout = ArcKitRecordLayout("menu_bar_preferences", fields: ["collectedApplications", "isEnabled", "deepSectionEnabled", "style", "opacity", "cornerRadius", "shelfShortcut", "revealShortcut", "toggleShortcut", "shortcutsEnabled"], json: ["collectedApplications", "shelfShortcut", "revealShortcut", "toggleShortcut"])
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
