import ArcKitPlatform
import AppKit

/// 管理页使用文字动作；内部排列锚点保持不可见，菜单栏切换另由品牌左侧原生按钮负责。
@MainActor
enum MenuBarControlAppearance {
    static func toggleIcon(for presentation: MenuBarPresentation) -> ArcIconName {
        presentation == .collapsed ? .eye : .eyeOff
    }

    static func actionLabel(for presentation: MenuBarPresentation) -> String {
        L10n.string(presentation == .collapsed ? .MenuBar.flowExpand : .MenuBar.flowCollapse)
    }

    static func concealAnchor(_ button: NSButton) {
        button.target = nil; button.action = nil
        button.isEnabled = false; button.isBordered = false
        button.title = ""; button.image = nil; button.toolTip = nil
        button.setAccessibilityLabel(nil)
        button.setAccessibilityElement(false)
    }
}
