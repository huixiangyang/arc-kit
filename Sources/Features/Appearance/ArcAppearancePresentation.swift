import ArcKitPlatform

// 图标属于展示层，持久化模型不依赖界面资源。
extension ArcAppearance {
    var icon: ArcIconName {
        switch self {
        case .system: .circleHalf
        case .dark: .moon
        case .light: .sun
        }
    }
}
