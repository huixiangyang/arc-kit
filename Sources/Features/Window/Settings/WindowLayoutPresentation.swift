import ArcKitPlatform
import ArcKitWindow

/// 窗口动作在快捷面板中的名称与 Lucide 图标，归窗口功能维护。
extension WindowLayoutAction {
    var menuBarTitle: String {
        switch self {
        case .leftThird: L10n.string(.WindowSettings.layoutLeftThird)
        case .centerThird: L10n.string(.WindowSettings.layoutMiddleThird)
        case .rightThird: L10n.string(.WindowSettings.layoutRightThird)
        case .leftTwoThirds: L10n.string(.WindowSettings.layoutLeftTwoThirds)
        case .rightTwoThirds: L10n.string(.WindowSettings.layoutRightTwoThirds)
        case .previousDisplay: L10n.string(.WindowSettings.layoutPreviousDisplay)
        case .nextDisplay: L10n.string(.WindowSettings.layoutNextDisplay)
        case .fullScreen: L10n.string(.WindowSettings.layoutFullScreen)
        case .restore: L10n.string(.Common.restore)
        default: displayName
        }
    }

    var menuBarIcon: ArcIconName {
        switch self {
        case .fill: .appWindowMac
        case .stageManager: .panelLeft
        case .center: .focus
        case .leftHalf: .panelLeft
        case .rightHalf: .panelRight
        case .topHalf: .panelTop
        case .bottomHalf: .panelBottom
        case .topLeft: .arrowUpLeft
        case .topRight: .arrowUpRight
        case .bottomLeft: .arrowDownLeft
        case .bottomRight: .arrowDownRight
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: .columns3
        case .previousDisplay, .nextDisplay: .monitor
        case .fullScreen: .maximize2
        case .restore: .undo2
        }
    }
}
