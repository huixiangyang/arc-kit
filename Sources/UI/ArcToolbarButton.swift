import ArcKitPlatform
import SwiftUI

/// 图标采用 Lucide；按钮的尺寸、焦点和禁用态由系统负责。
struct ArcToolbarButton: View {
    let title: String
    let symbol: ArcIconName
    var prominence: Prominence = .normal
    let action: () -> Void

    enum Prominence { case normal, primary, destructive }

    var body: some View {
        if prominence == .primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(role: prominence == .destructive ? .destructive : nil, action: action) {
            Label { Text(title) } icon: { ArcIcon(symbol, size: 13) }
        }
        .accessibilityLabel(title)
    }
}
