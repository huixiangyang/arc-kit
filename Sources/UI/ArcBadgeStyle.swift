import ArcKitPlatform
import SwiftUI

/// 状态徽标样式。
enum ArcBadgeStyle: Equatable {
    case good
    case warning
    case error
    case neutral
    case accent

    var foreground: Color {
        switch self {
        case .good:    ArcPalette.green
        case .warning: ArcPalette.orange
        case .error:   ArcPalette.red
        case .neutral: ArcPalette.secondaryText
        case .accent:  ArcPalette.accent
        }
    }

    var background: Color { foreground.opacity(0.14) }
    var border: Color { foreground.opacity(0.25) }
}
