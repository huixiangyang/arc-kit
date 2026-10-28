import CoreGraphics
import Foundation

/// 外观绘制只接收已确定的内容范围，不从固定图标数量猜测系统菜单宽度。
public enum MenuBarAppearanceStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, floating, split
    public var id: Self { self }
}

struct MenuBarAppearanceGeometry {
    static func regions(style: MenuBarAppearanceStyle, bar: CGRect, notch: CGRect?,
                        leadingWidth: CGFloat, trailingWidth: CGFloat, inset: CGFloat = 4) -> [CGRect] {
        guard [bar.minX, bar.minY, bar.width, bar.height, leadingWidth, trailingWidth, inset].allSatisfy(\.isFinite),
              bar.width > inset * 2, bar.height > inset * 2, inset >= 0,
              leadingWidth >= 0, trailingWidth >= 0 else { return [] }
        if style == .native { return [bar] }
        let content = bar.insetBy(dx: inset, dy: inset)
        let exclusion: CGRect? = notch.flatMap {
            guard [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite), $0.width > 0, $0.height > 0 else { return nil }
            let clipped = $0.intersection(bar)
            return clipped.isNull ? nil : clipped.insetBy(dx: -inset, dy: 0)
        }
        // 刘海属于硬件不可用区；“悬浮”也不能跨越它绘制或截断菜单内容。
        if let exclusion {
            let left = CGRect(x: content.minX, y: content.minY,
                width: max(0, exclusion.minX - content.minX), height: content.height)
            let right = CGRect(x: max(content.minX, exclusion.maxX), y: content.minY,
                width: max(0, content.maxX - exclusion.maxX), height: content.height)
            if style == .floating { return [left, right].filter { $0.width > 0 } }
            return trimmed(left: left, right: right, leadingWidth: leadingWidth, trailingWidth: trailingWidth)
        }
        if style == .floating { return [content] }
        // 内容过宽时保持一个连续区域，不让两个重叠胶囊产生加深接缝。
        if leadingWidth + trailingWidth + inset * 2 >= content.width { return [content] }
        return trimmed(left: content, right: content, leadingWidth: leadingWidth, trailingWidth: trailingWidth)
    }

    private static func trimmed(left: CGRect, right: CGRect, leadingWidth: CGFloat, trailingWidth: CGFloat) -> [CGRect] {
        let leading = CGRect(x: left.minX, y: left.minY, width: min(left.width, leadingWidth), height: left.height)
        let width = min(right.width, trailingWidth)
        let trailing = CGRect(x: right.maxX - width, y: right.minY, width: width, height: right.height)
        return [leading, trailing].filter { $0.width > 0 }
    }
}
