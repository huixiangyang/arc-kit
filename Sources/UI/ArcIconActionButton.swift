import ArcKitPlatform
import SwiftUI

/// 原生图标按钮保留动作名称供辅助功能与悬停帮助使用。
struct ArcIconActionButton: View {
    enum Emphasis { case normal, accent, destructive }

    let title: String
    let symbol: ArcIconName
    var emphasis: Emphasis = .normal
    let action: () -> Void

    var body: some View {
        Button(role: emphasis == .destructive ? .destructive : nil, action: action) {
            ArcIcon(symbol, size: 13)
        }
        .buttonStyle(.bordered)
        .tint(emphasis == .accent ? .accentColor : nil)
        .accessibilityLabel(title)
        .help(title)
    }
}
