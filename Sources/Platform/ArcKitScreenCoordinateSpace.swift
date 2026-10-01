import CoreGraphics
import Foundation

public struct ArcKitScreenCoordinateSpace: Equatable, Sendable {
    public var referenceMaxY: Double

    public init(primaryScreenFrame: CGRect) {
        referenceMaxY = primaryScreenFrame.maxY
    }

    public init(screenFrames: [CGRect]) {
        // NSScreen.main 随前台窗口变化；两个业务都必须以 AppKit 原点屏为基准。
        let primary = screenFrames.first { abs($0.minX) < 0.5 && abs($0.minY) < 0.5 }
            ?? screenFrames.first ?? .zero
        self.init(primaryScreenFrame: primary)
    }

    public init(referenceMaxY: Double) {
        self.referenceMaxY = referenceMaxY
    }

    /// Accessibility/CGEvent 使用屏幕顶部为 y 轴参考，AppKit 使用屏幕底部为 y 轴参考。
    public func appKitToAccessibility(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: referenceMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 预览窗口和 NSWindow 布局仍需要 AppKit 坐标。
    public func accessibilityToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: referenceMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
