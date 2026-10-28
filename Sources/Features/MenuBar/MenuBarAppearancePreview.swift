import ArcKitPlatform
import SwiftUI

struct MenuBarScenePreview: View {
    let style: MenuBarAppearanceStyle
    let opacity: Double
    let showsNotch: Bool
    var cornerRadius: Double = 9

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .top) {
                // 程序绘制的示意背景；不是用户壁纸截图，也不申请屏幕录制权限。
                LinearGradient(colors: [Color(red: 0.11, green: 0.15, blue: 0.18), Color(red: 0.25, green: 0.34, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.83, green: 0.53, blue: 0.32).opacity(0.35), .clear],
                    center: .bottomTrailing, startRadius: 20, endRadius: width * 0.8)
                Canvas { context, size in
                    let bar = CGRect(x: 0, y: 0, width: size.width, height: 38)
                    let notch = showsNotch ? CGRect(x: size.width / 2 - 65, y: 0, width: 130, height: 30) : nil
                    let regions = MenuBarAppearanceGeometry.regions(style: style, bar: bar, notch: notch, leadingWidth: 260, trailingWidth: 240)
                    for region in regions {
                        let path = Path(roundedRect: region, cornerRadius: style == .native ? 0 : cornerRadius)
                        context.fill(path, with: .color(.black.opacity(style == .native ? 0.22 : opacity)))
                        if style != .native { context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 0.7) }
                    }
                    if let notch { context.fill(Path(roundedRect: notch, cornerRadius: 9), with: .color(.black)) }
                }
                HStack(spacing: 17) {
                    ArcIcon(.command, size: 13)
                    Text("Arc Kit").fontWeight(.semibold)
                    Text(L10n.string(.MenuBar.previewFile))
                    if width > 700 {
                        Text(L10n.string(.MenuBar.previewEdit))
                        Text(L10n.string(.MenuBar.previewView))
                    }
                    Spacer()
                    ArcIcon(.chevronDown, size: 13)
                    if width > 700 { ArcIcon(.cloudDownload, size: 13) }
                    ArcIcon(.gauge, size: 13)
                    if width > 700 { ArcIcon(.sun, size: 13) }
                    Text("10:22").monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 18).frame(height: 38)
                VStack(alignment: .leading, spacing: 8) {
                    Text(style.title).font(.system(size: 25, weight: .medium))
                    Text(style.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    Text(L10n.string(.MenuBar.previewIllustration)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.40))
                }.foregroundStyle(.white).frame(width: width - 56, alignment: .leading).offset(y: 102)
            }
        }
    }
}

extension MenuBarAppearanceStyle {
    var title: String {
        switch self {
        case .native: L10n.string(.MenuBar.styleNative)
        case .floating: L10n.string(.MenuBar.styleFloating)
        case .split: L10n.string(.MenuBar.styleSplit)
        }
    }
    var detail: String {
        switch self {
        case .native: L10n.string(.MenuBar.styleNativeDetail)
        case .floating: L10n.string(.MenuBar.styleFloatingDetail)
        case .split: L10n.string(.MenuBar.styleSplitDetail)
        }
    }
}
