import ArcKitPlatform
import SwiftUI

/// 紧凑型状态标签。
struct ArcStatusBadge: View {
    let title: String
    let style: ArcBadgeStyle

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(style.background)
                    .overlay(Capsule().strokeBorder(style.border, lineWidth: 0.5))
            )
    }
}
