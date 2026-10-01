import ArcKitPlatform
import Foundation

public enum WindowLayoutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 铺满当前显示器可用区域，保留菜单栏与 Dock。
    case fill
    /// 靠右占可用宽度的 85%，左侧为台前调度缩略图留出空间。
    case stageManager
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds
    /// 进入或退出 macOS 全屏空间；与仅铺满可用区域的 fill 严格区分。
    case fullScreen
    case center
    case nextDisplay
    case previousDisplay
    case restore

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leftHalf: L10n.string(.Window.layoutLeftHalf)
        case .rightHalf: L10n.string(.Window.layoutRightHalf)
        case .topHalf: L10n.string(.Window.layoutTopHalf)
        case .bottomHalf: L10n.string(.Window.layoutBottomHalf)
        case .topLeft: L10n.string(.Window.layoutTopLeft)
        case .topRight: L10n.string(.Window.layoutTopRight)
        case .bottomLeft: L10n.string(.Window.layoutBottomLeft)
        case .bottomRight: L10n.string(.Window.layoutBottomRight)
        case .leftThird: L10n.string(.Window.layoutLeftThird)
        case .centerThird: L10n.string(.Window.layoutMiddleThird)
        case .rightThird: L10n.string(.Window.layoutRightThird)
        case .leftTwoThirds: L10n.string(.Window.layoutLeftTwoThirds)
        case .rightTwoThirds: L10n.string(.Window.layoutRightTwoThirds)
        case .fullScreen: L10n.string(.Window.layoutFullScreenDisplay)
        case .center: L10n.string(.Window.layoutCenter)
        case .fill: L10n.string(.Window.layoutMaximize)
        case .stageManager: L10n.string(.Window.layoutStageManager)
        case .nextDisplay: L10n.string(.Window.layoutMoveNextDisplay)
        case .previousDisplay: L10n.string(.Window.layoutMovePreviousDisplay)
        case .restore: L10n.string(.Window.layoutRestorePreviousPosition)
        }
    }
}

public enum WindowActionAvailability: Sendable {
    public static func isAvailable(_ action: WindowLayoutAction, screenCount: Int) -> Bool {
        guard screenCount > 0 else { return false }
        switch action {
        case .nextDisplay, .previousDisplay:
            return screenCount > 1
        default:
            return true
        }
    }

    public static func unavailableReason(_ action: WindowLayoutAction, screenCount: Int) -> String? {
        guard screenCount > 0 else { return L10n.string(.Window.layoutAvailableDisplayDetectedMissing) }
        guard !isAvailable(action, screenCount: screenCount) else { return nil }
        return L10n.string(.Window.layoutConnectSecondDisplay)
    }
}

public enum WindowDisplayNavigationStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case spatialOrder
    case systemOrder

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spatialOrder: L10n.string(.Window.layoutDisplayPosition)
        case .systemOrder: L10n.string(.Window.layoutSystemOrder)
        }
    }
}
