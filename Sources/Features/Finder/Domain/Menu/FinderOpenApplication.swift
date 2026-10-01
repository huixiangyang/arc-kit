import ArcKitPlatform
import Foundation

/// Finder 右键「用…打开」的固定应用列表。
public enum FinderOpenApplication: String, CaseIterable, Codable, Sendable, Identifiable {
    case vsCode
    case cursor
    case sublimeText
    case typora

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vsCode:      "VS Code"
        case .cursor:      "Cursor"
        case .sublimeText: "Sublime Text"
        case .typora:      "Typora"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .vsCode:      "com.microsoft.VSCode"
        case .cursor:      "com.todesktop.230313mzl4w4u92"
        case .sublimeText: "com.sublimetext.4"
        case .typora:      "abnerworks.Typora"
        }
    }
}
