import ArcKitPlatform
import AppKit

/// 菜单栏发现、分区和动作准入共用同一套屏幕几何，不使用随焦点变化的 NSScreen.main。
struct MenuBarScreenSnapshot: Equatable, Sendable {
    let displays: [MenuBarDisplay]
    let coordinates: ArcKitScreenCoordinateSpace

    @MainActor static func capture() -> Self? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let coordinates = ArcKitScreenCoordinateSpace(screenFrames: screens.map(\.frame))
        var displays: [MenuBarDisplay] = []
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let frame = coordinates.appKitToAccessibility(screen.frame)
            guard CGDisplayIsActive(id) != 0, frame == CGDisplayBounds(id) else { return nil }
            // NSStatusBar.thickness 在实机外屏上可返回 22，而系统菜单占用 31pt。
            // 使用每屏顶部保留区，避免叠层只画半高；自动隐藏时仍保留原生厚度下限。
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            let band = CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                height: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top, topInset))
            var notch: CGRect?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               right.minX > left.maxX, screen.safeAreaInsets.top > 0 {
                notch = coordinates.appKitToAccessibility(CGRect(x: left.maxX,
                    y: screen.frame.maxY - screen.safeAreaInsets.top,
                    width: right.minX - left.maxX, height: screen.safeAreaInsets.top))
            }
            displays.append(.init(id: id, name: screen.localizedName, frame: frame,
                topBand: band, notch: notch, scale: screen.backingScaleFactor))
        }
        return .init(displays: displays.sorted { $0.id < $1.id }, coordinates: coordinates)
    }
}
