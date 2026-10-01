import ArcKitPlatform
import ArcKitWindow
import Foundation

/// 菜单和设置共用捕获生命周期；关闭、重开及重复回包都不能复活旧目标。
struct WindowTargetSession {
    enum Phase {
        case idle
        case capturing(UUID)
        case resolved(UUID, WindowTargetCaptureResult)
    }

    private(set) var phase: Phase = .idle

    var requestID: UUID? {
        switch phase {
        case .idle: nil
        case .capturing(let id), .resolved(let id, _): id
        }
    }

    var result: WindowTargetCaptureResult {
        switch phase {
        case .idle: .unavailable(L10n.string(.WindowSettings.targetSelectTargetWindowOpening))
        case .capturing: .unavailable(L10n.string(.WindowSettings.targetReadingTargetWindowRetry))
        case .resolved(_, let result): result
        }
    }

    var targetID: UUID? { result.targetID }
    var failureMessage: String? { result.failureMessage }

    mutating func begin() -> UUID {
        let id = UUID()
        phase = .capturing(id)
        return id
    }

    @discardableResult
    mutating func complete(_ result: WindowTargetCaptureResult, for requestID: UUID) -> Bool {
        guard case .capturing(let activeID) = phase, activeID == requestID else { return false }
        phase = .resolved(requestID, result)
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}
