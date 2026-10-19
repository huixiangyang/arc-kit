import ArcKitPlatform
import ArcKitWindow
import AppKit

/// 一次读取配对全屏、可用区域和坐标基准，不按两次 NSScreen 枚举的下标拼接。
struct WindowScreenSnapshot {
    struct Screen: Equatable {
        let id: CGDirectDisplayID
        let name: String
        let fullFrame: CGRect
        let visibleFrame: CGRect
    }

    let screens: [Screen]
    let coordinates: ArcKitScreenCoordinateSpace

    @MainActor static func capture() -> Self {
        let native = NSScreen.screens
        let coordinates = ArcKitScreenCoordinateSpace(screenFrames: native.map(\.frame))
        var screens: [Screen] = []
        for screen in native {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return .init(screens: [], coordinates: coordinates)
            }
            let id = number.uint32Value
            let fullFrame = coordinates.appKitToAccessibility(screen.frame)
            // 已观察到后台保留旧分辨率。系统切屏事件尚未处理时拒绝布局，不按旧边界移动窗口。
            guard CGDisplayIsActive(id) != 0, fullFrame == CGDisplayBounds(id) else {
                return .init(screens: [], coordinates: coordinates)
            }
            screens.append(.init(id: id, name: screen.localizedName, fullFrame: fullFrame,
                                 visibleFrame: coordinates.appKitToAccessibility(screen.visibleFrame)))
        }
        return .init(screens: screens, coordinates: coordinates)
    }
}

struct WindowSnapTarget {
    let action: WindowLayoutAction
    let screen: WindowScreenSnapshot.Screen
    let preview: WindowSnapPreviewFrame
}
