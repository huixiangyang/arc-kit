import CoreGraphics
import Foundation

/// macOS 27 会丢弃过宽的单个状态项。用多个低于各屏可用区域一半的占位形成收纳范围。
/// 阈值方向参考 MenubarHide 的实机记录，具体布局必须由本机检查验证，不能用总宽度冒充可见性。
struct MenuBarOverflowPlan: Equatable, Sendable {
    let segmentLength: CGFloat
    let segmentCount: Int

    init(displays: [MenuBarDisplay]) throws {
        let available = displays.map { display in
            display.notch.map { display.frame.maxX - $0.maxX } ?? display.frame.width
        }
        guard let minimum = available.min(), let maximum = displays.map(\.frame.width).max(),
              minimum.isFinite, maximum.isFinite, minimum > 256, maximum > 0 else {
            throw MenuBarPartitionError.unavailable
        }
        segmentLength = floor(minimum / 2) - 64
        segmentCount = Int(ceil((maximum + 100) / segmentLength))
    }
}

/// 系统溢出菜单不提供可靠的普通/深度归属，不能继续套用离屏负坐标分区。
enum MenuBarPartitionMode: Sendable {
    case offscreen, systemOverflow

    static var current: Self {
        if #available(macOS 27.0, *) { return .systemOverflow }
        return .offscreen
    }
    var supportsSections: Bool { self == .offscreen }
    var presentations: [MenuBarPresentation] { supportsSections ? MenuBarPresentation.allCases : [.collapsed, .all] }
}
