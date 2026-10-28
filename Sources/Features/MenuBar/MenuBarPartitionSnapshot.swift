import ArcKitPlatform
import CoreGraphics
import Foundation

enum MenuBarShelfScope: String, CaseIterable, Identifiable, Sendable {
    case collected, all
    var id: Self { self }
    var title: String { L10n.string(self == .collected ? .MenuBar.scopeCollected : .MenuBar.scopeAll) }
}

enum MenuBarItemSection: Equatable, Sendable { case visible, collected, deep, unknown, otherDisplay }

/// 纯几何的分区凭据。包括原生变更代次，防止“展开再收起”后的同形布局复用旧观察。
struct MenuBarPartitionSnapshot: Equatable, Sendable {
    let generation: Int
    let displays: [MenuBarDisplay]
    let displayID: UInt32
    let control: CGRect
    let hidden: CGRect
    let deep: CGRect?

    init(generation: Int, displays: [MenuBarDisplay], control: CGRect, hidden: CGRect, deep: CGRect?) throws {
        guard control.isFiniteAndPositive, hidden.isFiniteAndPositive,
              let id = MenuBarDisplay.containing(control, in: displays),
              let display = displays.first(where: { $0.id == id }),
              display.topBand.contains(CGPoint(x: control.midX, y: control.midY)),
              hidden.maxX <= control.minX, abs(hidden.midY - control.midY) <= 8 else {
            throw MenuBarPartitionError.invalidOrder
        }
        if let deep {
            guard deep.isFiniteAndPositive, deep.maxX <= hidden.minX,
                  abs(deep.midY - control.midY) <= 8 else { throw MenuBarPartitionError.invalidOrder }
        }
        self.generation = generation; self.displays = displays; self.displayID = id
        self.control = control; self.hidden = hidden; self.deep = deep
    }

    func section(of item: MenuBarObservedItem) -> MenuBarItemSection {
        section(frame: item.frame)
    }

    /// 布局合法不代表收起生效：分隔线左侧还必须已经离开对应显示器。
    func confirmsHiddenSections(for state: MenuBarPresentation) -> Bool {
        guard let display = displays.first(where: { $0.id == displayID }) else { return false }
        switch state {
        case .all: return hidden.minX >= display.frame.minX && (deep == nil || deep!.minX >= display.frame.minX)
        case .collapsed: return hidden.minX < display.frame.minX && (deep == nil || deep!.minX < display.frame.minX)
        case .expanded: return hidden.minX >= display.frame.minX && (deep == nil || deep!.minX < display.frame.minX)
        }
    }

    func section(frame: CGRect?) -> MenuBarItemSection {
        guard let frame, frame.isFiniteAndPositive,
              let display = displays.first(where: { $0.id == displayID }) else { return .unknown }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let sameRow = display.topBand.minY <= frame.midY && frame.midY <= display.topBand.maxY
        if displays.contains(where: { $0.id != displayID && $0.topBand.contains(center) }) {
            // 收起后的逻辑坐标可能投影到同高度的另一块屏幕，不能据此泄漏或误分组。
            return sameRow ? .unknown : .otherDisplay
        }
        guard sameRow else { return .unknown }
        // 跨过分隔线的项目不能猜归属；收起后的离屏横坐标仍可按同屏分隔线判定。
        if frame.minX >= hidden.maxX && frame.maxX <= display.frame.maxX { return .visible }
        guard frame.maxX <= hidden.minX else { return .unknown }
        if let deep {
            if frame.maxX <= deep.minX { return .deep }
            if frame.minX >= deep.maxX { return .collected }
            return .unknown
        }
        return .collected
    }

    /// 只有一次发现前后的原生布局和屏幕均未变，才能把该快照用于分区筛选。
    static func validated(before: Self?, after: Self?, inventory: MenuBarInventory, targetDisplayID: UInt32?) -> Self? {
        guard let before, before == after, before.displays == inventory.displays,
              inventory.accessibility == .granted, inventory.canUseGeometry, targetDisplayID == before.displayID else { return nil }
        return before
    }
}

/// 普通收纳的动作约束只适用于该入口；全图标取用仍不要求可见坐标。
@MainActor
struct MenuBarCollectionConstraint {
    let snapshot: MenuBarPartitionSnapshot
    let isCurrent: () -> Bool
}
