import AppKit
import ArcKitPlatform
import SwiftUI

/// ImageGen 品牌资源随 Application 模块交付，安装版与 SwiftPM 调试使用同一份 PNG。
@MainActor
enum ArcBrandImage {
    private static let light = load("ArcKitLogo")
    private static let dark = load("ArcKitLogoDark")
    static let menuBar: NSImage = {
        // 菜单栏直接使用同一标记的透明轮廓，由系统按外观着色。
        let image = load("ArcKitLogo")
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    static func logo(for colorScheme: ColorScheme) -> NSImage {
        colorScheme == .dark ? dark : light
    }

    private static func load(_ name: String) -> NSImage {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ArcBrandBundleLocator.self)
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else {
            // 缺资源是打包故障；记录证据，不再回退到另一套过时品牌绘制。
            ArcKitLog.append("brand resource missing name=\(name)")
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        return image
    }
}

private final class ArcBrandBundleLocator {}

struct ArcBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat

    var body: some View {
        Image(nsImage: ArcBrandImage.logo(for: colorScheme))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
            .accessibilityLabel("Arc Kit")
    }
}
