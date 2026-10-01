import ArcKitPlatform
import SwiftUI

/// SwiftUI 统一 Lucide 图标视图。尺寸由组件显式决定，不再借用字体大小间接控制图标。
struct ArcIcon: View {
    let name: ArcIconName
    var size: CGFloat = 16

    init(_ name: ArcIconName, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(nsImage: ArcIconImage.image(name))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 品牌组件使用的语义别名。别名仍指向 Lucide 资源，不允许再引入第二套图标库。
extension ArcIconName {
    static let arcOverview: Self = .layoutDashboard
    static let arcMouse: Self = .mouse
    static let arcFinder: Self = .folder
    static let arcSystem: Self = .wrench
    static let arcSettings: Self = .settings
    static let arcAbout: Self = .circleInfo
    static let arcCheck: Self = .checkCircle
    static let arcWarning: Self = .triangleAlert
    static let arcRefresh: Self = .refreshCw
    static let arcPlus: Self = .plus
    static let arcTrash: Self = .trash2
    static let arcArrowUp: Self = .arrowUp
    static let arcArrowDown: Self = .arrowDown
    static let arcTerminal: Self = .terminal
    static let arcEditor: Self = .braces
    static let arcFile: Self = .fileText
    static let arcHash: Self = .hash
    static let arcDock: Self = .appWindowMac
    static let arcExternalDrive: Self = .hardDrive
    static let arcBolt: Self = .activity
    static let arcShield: Self = .shieldCheck
    static let arcMagnifyingglass: Self = .search
    static let arcStar: Self = .sparkles
    static let arcFolderBadge: Self = .folderCog
    static let arcExtVolume: Self = .hardDriveUpload
    static let icloudDrive: Self = .cloudDownload
}
