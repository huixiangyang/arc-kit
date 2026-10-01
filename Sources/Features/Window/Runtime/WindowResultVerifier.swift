import ArcKitWindow
import Foundation

/// 单次窗口写入后的结果校验。封装 AX 异步收敛、Space 动画稳定期和最小尺寸约束。
@MainActor
struct WindowResultVerifier {
    let accessibilityClient: WindowAccessibilityClient
    let fullScreenVerificationStableInterval: TimeInterval

    init(accessibilityClient: WindowAccessibilityClient, fullScreenVerificationStableInterval: TimeInterval) {
        self.accessibilityClient = accessibilityClient
        self.fullScreenVerificationStableInterval = max(0, fullScreenVerificationStableInterval)
    }

    func framesMatch(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(actual.minX - expected.minX) <= tolerance
            && abs(actual.minY - expected.minY) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
    }

    func verifiedFrame(for target: WindowActionTarget, expected: CGRect) async throws -> CGRect {
        var latestFrame = try await accessibilityClient.frame(of: target)
        let deadline = Date().addingTimeInterval(0.45)
        while !framesMatch(latestFrame, expected), Date() < deadline {
            // 不同 App 的 AXPosition/AXSize 会先返回 success，再异步完成真实布局；短轮询避免把成功移动误判为失败。
            try await Task.sleep(for: .milliseconds(30))
            latestFrame = try await accessibilityClient.frame(of: target)
        }
        return latestFrame
    }

    func verifiedFullScreenState(for target: WindowActionTarget, expected: Bool) async throws -> Bool {
        var latestState = try await accessibilityClient.isWindowFullScreen(target)
        let deadline = Date().addingTimeInterval(4)
        var stableSince: Date? = latestState == expected ? Date() : nil
        while Date() < deadline {
            if latestState == expected {
                if stableSince == nil { stableSince = Date() }
                if let stableSince,
                   Date().timeIntervalSince(stableSince) >= fullScreenVerificationStableInterval {
                    return latestState
                }
            } else {
                stableSince = nil
            }
            // AXFullScreen 会在 Space 切换动画结束前提前翻转；必须连续稳定一段时间，
            // 否则紧接着执行退出会被系统静默忽略。
            try await Task.sleep(for: .milliseconds(50))
            latestState = try await accessibilityClient.isWindowFullScreen(target)
        }
        return latestState
    }

    func frameWasConstrainedButApplied(
        actual: CGRect,
        expected: CGRect,
        original: CGRect,
        action: WindowLayoutAction,
        screen: CGRect
    ) -> Bool {
        // 此预设的目标就是留出缩略图区，最小尺寸导致越界时不能以受约束成功掩盖。
        // 精确命中已由调用方判断；台前调度不接受偏离目标的近似结果。
        guard action != .stageManager else { return false }
        guard !framesMatch(actual, original),
              !actual.isNull,
              !expected.isNull,
              !screen.isNull,
              actual.area > 0,
              expected.area > 0,
              screen.area > 0
        else { return false }
        let intersectionArea = actual.intersection(expected).area
        let expectedCoverage = intersectionArea / expected.area
        let actualCoverage = intersectionArea / actual.area
        if expectedCoverage >= 0.85, actualCoverage >= 0.9 {
            return true
        }

        // Finder 等 App 会强制最小窗口尺寸：目标区域已完整覆盖且锚点正确时，应视为受约束成功。
        let screenCoverage = actual.intersection(screen).area / actual.area
        let expansionRatio = actual.area / expected.area
        let actualError = frameDistance(actual, expected)
        let originalError = frameDistance(original, expected)
        return expectedCoverage >= 0.85
            && screenCoverage >= 0.98
            && expansionRatio <= 2.25
            && actualError < originalError
            && constrainedAnchorsMatch(action: action, actual: actual, expected: expected)
    }

    private func constrainedAnchorsMatch(
        action: WindowLayoutAction,
        actual: CGRect,
        expected: CGRect,
        tolerance: CGFloat = 3
    ) -> Bool {
        let left = abs(actual.minX - expected.minX) <= tolerance
        let right = abs(actual.maxX - expected.maxX) <= tolerance
        let horizontalCenter = abs(actual.midX - expected.midX) <= tolerance
        let top = abs(actual.minY - expected.minY) <= tolerance
        let bottom = abs(actual.maxY - expected.maxY) <= tolerance
        let verticalCenter = abs(actual.midY - expected.midY) <= tolerance

        switch action {
        case .leftHalf, .leftThird, .leftTwoThirds:
            return left && top && bottom
        case .rightHalf, .rightThird, .rightTwoThirds:
            return right && top && bottom
        case .centerThird:
            return horizontalCenter && top && bottom
        case .topHalf:
            return left && right && top
        case .bottomHalf:
            return left && right && bottom
        case .topLeft:
            return left && top
        case .topRight:
            return right && top
        case .bottomLeft:
            return left && bottom
        case .bottomRight:
            return right && bottom
        case .center:
            return horizontalCenter && verticalCenter
        case .fill:
            return left && right && top && bottom
        case .stageManager, .fullScreen, .nextDisplay, .previousDisplay, .restore:
            return false
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

}

extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func containsInclusive(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
