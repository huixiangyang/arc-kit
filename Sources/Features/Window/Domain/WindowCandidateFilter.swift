import ArcKitPlatform
import CoreGraphics
import Foundation

public struct WindowCandidateMetadata: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var isModal: Bool
    public var isMinimized: Bool
    public var isFullScreen: Bool
    public var frame: CGRect

    public init(
        role: String?,
        subrole: String?,
        isModal: Bool = false,
        isMinimized: Bool = false,
        isFullScreen: Bool = false,
        frame: CGRect
    ) {
        self.role = role
        self.subrole = subrole
        self.isModal = isModal
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.frame = frame
    }
}

public enum WindowCandidateRejectionReason: String, Equatable, Sendable {
    case nonWindow
    case modal
    case minimized
    case fullScreen
    case tooSmall
    case unsupportedSubrole
}

/// 在进入 AX 写入链路前统一拒绝非标准、模态、最小化和全屏窗口。
public enum WindowCandidateFilter: Sendable {
    public static func rejectionReason(for metadata: WindowCandidateMetadata) -> WindowCandidateRejectionReason? {
        guard metadata.role == "AXWindow" else { return .nonWindow }
        guard !metadata.isModal else { return .modal }
        guard !metadata.isMinimized else { return .minimized }
        guard !metadata.isFullScreen else { return .fullScreen }
        guard metadata.frame.width >= 80, metadata.frame.height >= 60 else { return .tooSmall }
        // 破坏性收紧：只管理明确的标准窗口，未知 subrole 不再为了兼容而放行。
        guard metadata.subrole == "AXStandardWindow" else { return .unsupportedSubrole }
        return nil
    }

    public static func isManageable(_ metadata: WindowCandidateMetadata) -> Bool {
        rejectionReason(for: metadata) == nil
    }
}
