import ArcKitPlatform
import ArcKitFinder
import AppKit
import SwiftUI

// MARK: - App icon helpers

extension FavoriteApplication {
    /// 获取应用路径（通过 bundleID 或 appPath）。
    var resolvedAppURL: URL? {
        if let path = appPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bid = bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        }
        return nil
    }

    /// 获取应用图标，失败时返回 nil。
    func loadIcon(size: NSSize = NSSize(width: 20, height: 20)) -> NSImage? {
        guard let url = resolvedAppURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = size
        return icon
    }
}

/// SwiftUI 中显示应用图标。
struct AppIconView: View {
    let app: FavoriteApplication
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let nsImage = app.loadIcon(size: NSSize(width: size, height: size)) {
                nsImage.swiftUIImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ArcIcon(.squareDashed, size: size * 0.72)
                    .foregroundStyle(ArcPalette.mutedText)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - File type icon

/// 新建文件模板图标：优先展示对应应用图标，和 Finder 右键菜单保持一致。
struct NewFileTemplateIconView: View {
    let template: ConfigurableNewFileTemplate
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let nsImage = NewFileTemplateIcon(template: template).loadImage() {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ArcIcon(template.icon, size: size * 0.8)
                    .foregroundStyle(ArcPalette.mutedText)
            }
        }
        .frame(width: size, height: size)
    }
}
