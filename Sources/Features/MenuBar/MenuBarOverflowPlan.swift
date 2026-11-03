import CoreGraphics
import Foundation
import AppKit

// 历史分段宽度仅供开发实验，不再编入正式收纳机制。
#if DEBUG
/// 槽位始终注册；展开与收起只改变长度，不反复移出、插入系统排列。
@MainActor
protocol MenuBarSpacerItem: AnyObject {
    var length: CGFloat { get set }
    var isVisible: Bool { get set }
}

extension NSStatusItem: MenuBarSpacerItem {}

@MainActor
enum MenuBarSpacerLayout {
    nonisolated static let stagingLength: CGFloat = 1
    // macOS 27 会排除超过单项宽度上限的项目，但保留它在排列中的位置。
    // 不能用 isVisible=false：重新显示会把槽位插到最左侧；length=0 又会留下 16pt 边距。
    nonisolated static let inactiveLength: CGFloat = 10000

    /// 从排除宽度恢复到小尺寸后再放大，整个过程保持同一组已注册槽位。
    static func stage<Item: MenuBarSpacerItem>(_ items: [Item], plan: MenuBarOverflowPlan) throws -> [Item] {
        let count = plan.segmentCount - 1
        guard items.count >= count else { throw MenuBarPartitionError.overflowCapacity }
        for (index, item) in items.enumerated() {
            if index < count {
                item.length = stagingLength
                item.isVisible = true
            } else {
                item.isVisible = true
                item.length = inactiveLength
            }
        }
        return Array(items.prefix(count))
    }

    static func inflate<Item: MenuBarSpacerItem>(_ items: [Item], plan: MenuBarOverflowPlan) throws {
        guard items.count == plan.segmentCount - 1,
              items.allSatisfy({ $0.isVisible && $0.length == stagingLength }) else {
            throw MenuBarPartitionError.layoutUnconfirmed
        }
        // 此阶段不再改变可见性，避免按保存位置逐个重新插入而夹进第三方图标。
        for item in items { item.length = plan.segmentLength }
    }

    static func reveal<Item: MenuBarSpacerItem>(_ items: [Item]) {
        for item in items {
            // 超宽项退出可见布局，而非退出注册表；下一次收起仍处于原来的连续位置。
            item.isVisible = true
            item.length = inactiveLength
        }
    }

    static func isReleased<Item: MenuBarSpacerItem>(_ items: [Item]) -> Bool {
        items.allSatisfy { $0.isVisible && $0.length == inactiveLength }
    }
}

/// macOS 27 的刘海区域和普通屏幕具有不同的宽度上限；每段均留出安全余量。
/// 固定槽位数量，避免显示器变化时新增名字落到左端、破坏连续区域。
struct MenuBarOverflowPlan: Equatable, Sendable {
    static let spacerCapacity = 6
    let segmentLength: CGFloat
    let segmentCount: Int

    init(displays: [MenuBarDisplay]) throws {
        let areas = displays.map { display in
            display.notch.map { display.frame.maxX - $0.maxX } ?? display.frame.width
        }
        let cliffs = zip(displays, areas).map { display, area in
            display.notch == nil ? display.frame.width / 2 : area * 0.75
        }
        guard !displays.isEmpty, areas.allSatisfy({ $0.isFinite && $0 > 0 }),
              let lowest = cliffs.min(), let widest = areas.max(), lowest.isFinite,
              cliffs.allSatisfy({ $0 < MenuBarSpacerLayout.inactiveLength }) else {
            throw MenuBarPartitionError.unavailable
        }
        let unit = floor(lowest - 64)
        guard unit > MenuBarSpacerLayout.stagingLength else { throw MenuBarPartitionError.unavailable }
        let count = ceil(widest / unit)
        guard count <= CGFloat(Self.spacerCapacity + 1) else { throw MenuBarPartitionError.overflowCapacity }
        segmentLength = unit
        segmentCount = Int(count)
    }
}

#endif

/// macOS 27 按应用收纳，不再套用离屏坐标分区或系统溢出占位。
enum MenuBarPartitionMode: Sendable {
    case offscreen, systemVisibility

    static var current: Self {
        if #available(macOS 27.0, *) { return .systemVisibility }
        return .offscreen
    }
    var supportsSections: Bool { self == .offscreen }
    var presentations: [MenuBarPresentation] { supportsSections ? MenuBarPresentation.allCases : [.collapsed, .all] }
}
