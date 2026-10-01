import ArcKitPlatform
import CoreGraphics
import Foundation

/// 纯逻辑拖拽判定策略；不持有 EventTap、AX 元素或窗口生命周期状态。
public struct WindowDragSnapPolicy: Equatable, Sendable {
    public var titleBarHeight: Double
    public var minimumDragDistance: Double

    public init(titleBarHeight: Double = 52, minimumDragDistance: Double = 12) {
        self.titleBarHeight = titleBarHeight
        self.minimumDragDistance = minimumDragDistance
    }

    public func canBegin(at location: CGPoint, windowFrame: CGRect, hitTestRole: String?) -> Bool {
        canBegin(at: location, windowFrame: windowFrame, hitTestRoles: hitTestRole.map { [$0] } ?? [])
    }

    public func canBegin(at location: CGPoint, windowFrame: CGRect, hitTestRoles: [String]) -> Bool {
        guard windowFrame.contains(location) else { return false }
        // AX 命中常落在控件里的文字节点；必须检查整条父级角色链，避免拖按钮文字、标签标题或搜索框文字时误触吸附。
        if hitTestRoles.contains(where: { Self.blockedRoles.contains($0) }) {
            return false
        }
        if hitTestRoles.contains(where: { Self.draggableChromeRoles.contains($0) }) {
            return true
        }
        return location.y <= windowFrame.minY + titleBarHeight
    }

    public func hasMeaningfulDrag(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= minimumDragDistance
    }

    private static let draggableChromeRoles: Set<String> = [
        "AXTitleBar",
        "AXToolbar",
    ]

    private static let blockedRoles: Set<String> = [
        "AXBrowser",
        "AXButton",
        "AXCell",
        "AXCheckBox",
        "AXColorWell",
        "AXComboBox",
        "AXColumn",
        "AXDateField",
        "AXDisclosureTriangle",
        "AXGrid",
        "AXImage",
        "AXIncrementor",
        "AXLink",
        "AXList",
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXMenuItem",
        "AXOutline",
        "AXPopUpButton",
        "AXRadioButton",
        "AXRadioGroup",
        "AXRow",
        "AXScrollArea",
        "AXSearchField",
        "AXSegmentedControl",
        "AXSlider",
        "AXSortButton",
        "AXStepper",
        "AXSplitGroup",
        "AXSwitch",
        "AXTabGroup",
        "AXTable",
        "AXTextArea",
        "AXTextField",
        "AXValueIndicator",
    ]
}
