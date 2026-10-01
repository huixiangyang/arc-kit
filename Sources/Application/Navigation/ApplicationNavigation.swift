import ArcKitPlatform
import ArcKitWindow
import Foundation

public enum PreferencesWorkspaceTarget: String, Hashable, Sendable, CaseIterable, Identifiable {
    case application, background, dataManagement, about
    public var id: Self { self }
    var title: String {
        switch self {
        case .application: L10n.string(.App.searchGeneral)
        case .background: L10n.string(.App.searchBackground)
        case .dataManagement: L10n.string(.App.searchDataManagement)
        case .about: L10n.string(.App.searchAbout)
        }
    }
}

enum ArcKitQuickCommandAction: Hashable, Sendable {
    case section(MainWindowSection)
    case overview(OverviewWorkspaceTab)
    case finder(FinderWorkspaceTab)
    case wallpaper(WallpaperWorkspaceTab)
    case preferences(PreferencesWorkspaceTarget)
    case window(WindowLayoutAction)
}

struct ArcKitQuickCommand: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: ArcIconName
    let category: String
    let keywords: [String]
    let action: ArcKitQuickCommandAction
    let isSuggested: Bool
    let stableOrder: Int
}

extension ArcKitQuickCommand {
    static func command(
        _ id: String,
        _ title: String,
        _ detail: String,
        _ symbol: ArcIconName,
        _ category: String,
        _ keywords: [String],
        _ action: ArcKitQuickCommandAction,
        suggested: Bool = false,
        order: Int
    ) -> ArcKitQuickCommand {
        ArcKitQuickCommand(
            id: id,
            title: title,
            detail: detail,
            symbol: symbol,
            category: category,
            keywords: keywords,
            action: action,
            isSuggested: suggested,
            stableOrder: order
        )
    }

}
