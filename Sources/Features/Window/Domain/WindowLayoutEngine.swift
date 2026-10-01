import ArcKitPlatform
import CoreGraphics
import Foundation

public struct WindowLayoutInput: Equatable, Sendable {
    public var action: WindowLayoutAction
    public var currentFrame: CGRect
    public var currentScreenVisibleFrame: CGRect
    public var allScreenVisibleFrames: [CGRect]
    public var previousFrame: CGRect?
    public var gap: Double
    public var displayNavigationStrategy: WindowDisplayNavigationStrategy

    public init(
        action: WindowLayoutAction,
        currentFrame: CGRect,
        currentScreenVisibleFrame: CGRect,
        allScreenVisibleFrames: [CGRect],
        previousFrame: CGRect? = nil,
        gap: Double = 0,
        displayNavigationStrategy: WindowDisplayNavigationStrategy = .spatialOrder
    ) {
        self.action = action
        self.currentFrame = currentFrame
        self.currentScreenVisibleFrame = currentScreenVisibleFrame
        self.allScreenVisibleFrames = allScreenVisibleFrames
        self.previousFrame = previousFrame
        self.gap = gap
        self.displayNavigationStrategy = displayNavigationStrategy
    }
}

public enum WindowLayoutEngineError: Error, Equatable {
    case missingRestoreFrame
    case missingDisplay
    /// 全屏显示由 AXFullScreen 状态机执行，不允许伪装成几何布局。
    case nonGeometricAction
}

public struct WindowLayoutEngine: Sendable {
    public init() {}

    public func frame(for input: WindowLayoutInput) throws -> CGRect {
        guard !input.allScreenVisibleFrames.isEmpty else {
            throw WindowLayoutEngineError.missingDisplay
        }
        let screenFrame = input.currentScreenVisibleFrame
        let visibleFrame = inset(screenFrame, gap: input.gap)
        switch input.action {
        case .leftHalf:
            return layoutCell(in: screenFrame, columns: 2, rows: 1, column: 0, row: 0, gap: input.gap)
        case .rightHalf:
            return layoutCell(in: screenFrame, columns: 2, rows: 1, column: 1, row: 0, gap: input.gap)
        case .topHalf:
            return layoutCell(in: screenFrame, columns: 1, rows: 2, column: 0, row: 0, gap: input.gap)
        case .bottomHalf:
            return layoutCell(in: screenFrame, columns: 1, rows: 2, column: 0, row: 1, gap: input.gap)
        case .topLeft:
            return layoutCell(in: screenFrame, columns: 2, rows: 2, column: 0, row: 0, gap: input.gap)
        case .topRight:
            return layoutCell(in: screenFrame, columns: 2, rows: 2, column: 1, row: 0, gap: input.gap)
        case .bottomLeft:
            return layoutCell(in: screenFrame, columns: 2, rows: 2, column: 0, row: 1, gap: input.gap)
        case .bottomRight:
            return layoutCell(in: screenFrame, columns: 2, rows: 2, column: 1, row: 1, gap: input.gap)
        case .leftThird:
            return layoutCell(in: screenFrame, columns: 3, rows: 1, column: 0, row: 0, gap: input.gap)
        case .centerThird:
            return layoutCell(in: screenFrame, columns: 3, rows: 1, column: 1, row: 0, gap: input.gap)
        case .rightThird:
            return layoutCell(in: screenFrame, columns: 3, rows: 1, column: 2, row: 0, gap: input.gap)
        case .leftTwoThirds:
            return layoutCell(in: screenFrame, columns: 3, rows: 1, column: 0, row: 0, columnSpan: 2, gap: input.gap)
        case .rightTwoThirds:
            return layoutCell(in: screenFrame, columns: 3, rows: 1, column: 1, row: 0, columnSpan: 2, gap: input.gap)
        case .fullScreen:
            throw WindowLayoutEngineError.nonGeometricAction
        case .center:
            return centered(current: input.currentFrame, visible: visibleFrame, previous: input.previousFrame)
        case .fill:
            return visibleFrame
        case .stageManager:
            // 以当前显示器可用区域计算，先预留左侧 15%，再应用用户设置的边距。
            // 这是手动布局预设，不读取私有系统开关，也不切换台前调度状态。
            return inset(CGRect(
                x: screenFrame.minX + screenFrame.width * 0.15,
                y: screenFrame.minY,
                width: screenFrame.width * 0.85,
                height: screenFrame.height
            ), gap: input.gap)
        case .nextDisplay:
            return try movedToDisplay(input: input, offset: 1)
        case .previousDisplay:
            return try movedToDisplay(input: input, offset: -1)
        case .restore:
            guard let previousFrame = input.previousFrame else { throw WindowLayoutEngineError.missingRestoreFrame }
            return restored(previousFrame: previousFrame, input: input, visibleFrame: visibleFrame)
        }
    }

    public func snapAction(for point: CGPoint, visibleFrame: CGRect, threshold: Double = 48) -> WindowLayoutAction? {
        snapAction(for: point, visibleFrame: visibleFrame, allVisibleFrames: [visibleFrame], threshold: threshold)
    }

    public func snapAction(
        for point: CGPoint,
        visibleFrame: CGRect,
        allVisibleFrames: [CGRect],
        threshold: Double = 48
    ) -> WindowLayoutAction? {
        let visibleFrames = allVisibleFrames.isEmpty ? [visibleFrame] : allVisibleFrames
        let nearLeft = point.x <= visibleFrame.minX + threshold && isOuterEdge(.left, of: visibleFrame, at: point, in: visibleFrames)
        let nearRight = point.x >= visibleFrame.maxX - threshold && isOuterEdge(.right, of: visibleFrame, at: point, in: visibleFrames)
        let nearTop = point.y <= visibleFrame.minY + threshold && isOuterEdge(.top, of: visibleFrame, at: point, in: visibleFrames)
        let nearBottom = point.y >= visibleFrame.maxY - threshold && isOuterEdge(.bottom, of: visibleFrame, at: point, in: visibleFrames)

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, false, true, false): return .topLeft
        case (false, true, true, false): return .topRight
        case (true, false, false, true): return .bottomLeft
        case (false, true, false, true): return .bottomRight
        case (true, false, false, false): return .leftHalf
        case (false, true, false, false): return .rightHalf
        case (false, false, true, false): return .fill
        case (false, false, false, true): return .bottomHalf
        default: return nil
        }
    }

    private enum SnapEdge {
        case left
        case right
        case top
        case bottom
    }

    private func isOuterEdge(_ edge: SnapEdge, of frame: CGRect, at point: CGPoint, in frames: [CGRect]) -> Bool {
        for other in frames where other != frame {
            switch edge {
            case .left:
                if abs(other.maxX - frame.minX) <= 2, other.minY...other.maxY ~= point.y { return false }
            case .right:
                if abs(other.minX - frame.maxX) <= 2, other.minY...other.maxY ~= point.y { return false }
            case .top:
                if abs(other.maxY - frame.minY) <= 2, other.minX...other.maxX ~= point.x { return false }
            case .bottom:
                if abs(other.minY - frame.maxY) <= 2, other.minX...other.maxX ~= point.x { return false }
            }
        }
        return true
    }

    private func movedToDisplay(input: WindowLayoutInput, offset: Int) throws -> CGRect {
        let displays = orderedDisplays(input.allScreenVisibleFrames, strategy: input.displayNavigationStrategy)
        guard displays.count > 1 else { throw WindowLayoutEngineError.missingDisplay }
        guard let sourceIndex = displays.indices.max(by: {
            displays[$0].intersection(input.currentFrame).area < displays[$1].intersection(input.currentFrame).area
        }), displays[sourceIndex].intersection(input.currentFrame).area > 0 else {
            throw WindowLayoutEngineError.missingDisplay
        }
        let targetIndex = (sourceIndex + offset + displays.count) % displays.count
        let source = displays[sourceIndex]
        let target = inset(displays[targetIndex], gap: input.gap)
        let relativeX = input.currentFrame.minX - source.minX
        let relativeY = input.currentFrame.minY - source.minY
        let xRatio = source.width == 0 ? 0 : relativeX / source.width
        let yRatio = source.height == 0 ? 0 : relativeY / source.height
        let width = min(input.currentFrame.width, target.width)
        let height = min(input.currentFrame.height, target.height)
        let proposedX = target.minX + target.width * xRatio
        let proposedY = target.minY + target.height * yRatio
        return CGRect(
            x: clamp(proposedX, min: target.minX, max: target.maxX - width),
            y: clamp(proposedY, min: target.minY, max: target.maxY - height),
            width: width,
            height: height
        )
    }

    private func orderedDisplays(_ displays: [CGRect], strategy: WindowDisplayNavigationStrategy) -> [CGRect] {
        switch strategy {
        case .systemOrder:
            return displays
        case .spatialOrder:
            // AX 坐标中 y 越小越靠上；先按横向位置，再按纵向位置，保证多屏循环稳定可预测。
            return displays.sorted {
                if abs($0.minX - $1.minX) > 1 { return $0.minX < $1.minX }
                return $0.minY < $1.minY
            }
        }
    }

    private func centered(current: CGRect, visible: CGRect, previous: CGRect?) -> CGRect {
        let fillsVisibleFrame = abs(current.minX - visible.minX) <= 2
            && abs(current.minY - visible.minY) <= 2
            && abs(current.width - visible.width) <= 2
            && abs(current.height - visible.height) <= 2

        let preferredSize: CGSize
        if fillsVisibleFrame,
           let previous,
           previous.width >= 160,
           previous.height >= 120,
           previous.width < visible.width - 2 || previous.height < visible.height - 2 {
            preferredSize = previous.size
        } else if fillsVisibleFrame {
            // 已铺满的窗口仅改坐标不会产生任何视觉反馈；恢复为可用区域的 80% 后再居中。
            preferredSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        } else {
            preferredSize = current.size
        }
        let width = min(preferredSize.width, visible.width)
        let height = min(preferredSize.height, visible.height)
        return CGRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func layoutCell(
        in frame: CGRect,
        columns: Int,
        rows: Int,
        column: Int,
        row: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1,
        gap: Double
    ) -> CGRect {
        let cellWidth = frame.width / Double(columns)
        let cellHeight = frame.height / Double(rows)
        let cell = CGRect(
            x: frame.minX + Double(column) * cellWidth,
            y: frame.minY + Double(row) * cellHeight,
            width: Double(columnSpan) * cellWidth,
            height: Double(rowSpan) * cellHeight
        )
        // 每个布局单元独立缩进，外边缘和相邻窗口之间都会产生真实间距。
        return inset(cell, gap: gap)
    }

    private func restored(previousFrame: CGRect, input: WindowLayoutInput, visibleFrame: CGRect) -> CGRect {
        if input.allScreenVisibleFrames.contains(where: { $0.intersection(previousFrame).area > 0 }) {
            return previousFrame
        }
        let width = min(previousFrame.width, visibleFrame.width)
        let height = min(previousFrame.height, visibleFrame.height)
        return CGRect(
            x: clamp(previousFrame.minX, min: visibleFrame.minX, max: visibleFrame.maxX - width),
            y: clamp(previousFrame.minY, min: visibleFrame.minY, max: visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    private func inset(_ frame: CGRect, gap: Double) -> CGRect {
        guard gap > 0 else { return frame }
        let maximumSafeGap = max(0, min(frame.width, frame.height) / 2 - 1)
        let safeGap = min(gap, maximumSafeGap)
        return frame.insetBy(dx: safeGap, dy: safeGap)
    }

    private func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.max(minimum, Swift.min(value, maximum))
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

public struct WindowManagementResult: Codable, Equatable, Sendable {
    public var succeeded: Bool
    public var userMessage: String?
    public var diagnosticFields: [String: String]

    public init(succeeded: Bool, userMessage: String? = nil, diagnosticFields: [String: String] = [:]) {
        self.succeeded = succeeded
        self.userMessage = userMessage
        self.diagnosticFields = diagnosticFields
    }
}
