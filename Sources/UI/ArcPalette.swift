import ArcKitPlatform
import AppKit
import SwiftUI

/// 面板唯一语义色表；原生控件、侧栏、内容和菜单共享外观。
enum ArcPalette {
    // 直接采用系统语义色，跟随深浅外观、强调色和辅助功能对比度。
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panelSecondary = Color(nsColor: .underPageBackgroundColor)
    static let panelBorder = Color(nsColor: .separatorColor)
    static let divider = Color(nsColor: .separatorColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let mutedText = Color(nsColor: .secondaryLabelColor)
    static let sidebarMutedText = secondaryText
    static let sidebarActive = Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
    static let controlAccent = NSColor.controlAccentColor
    static let accent = Color.accentColor
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)

}

/// 窗口最小尺寸保证配置标签、控件与系统侧栏可同时显示。
enum ArcMetrics {
    static let mainWindowMinWidth: CGFloat = 720
    static let mainWindowMinHeight: CGFloat = 560
    static let mainWindowDefaultWidth: CGFloat = 820
    static let mainWindowDefaultHeight: CGFloat = 620
    static let calloutRadius: CGFloat = 8
}
