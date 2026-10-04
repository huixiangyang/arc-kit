import ArcKitPlatform
import ArcKitWindow
import ApplicationServices
import Foundation

protocol WindowAXFrameIO {
    func setPosition(_ position: CGPoint, for window: AXUIElement) -> AXError
    func setSize(_ size: CGSize, for window: AXUIElement) -> AXError
    func frame(of window: AXUIElement) throws -> CGRect
}

struct SystemWindowAXFrameIO: WindowAXFrameIO {
    func setPosition(_ position: CGPoint, for window: AXUIElement) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize, for window: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    func frame(of window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              let positionAX = WindowAXTypeSafety.axValue(positionValue, expectedType: .cgPoint),
              let sizeAX = WindowAXTypeSafety.axValue(sizeValue, expectedType: .cgSize)
        else {
            throw WindowManagementExecutionError.unreadableWindow
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            throw WindowManagementExecutionError.unreadableWindow
        }
        return CGRect(origin: position, size: size)
    }
}

/// AXPosition 与 AXSize 在 Finder 等 App 中会分阶段异步生效，必须等待每一步收敛后再继续写入。
struct WindowAXFrameWriter {
    private let io: any WindowAXFrameIO
    private let settle: (TimeInterval) -> Void
    private let diagnostic: (String) -> Void

    init(
        io: any WindowAXFrameIO = SystemWindowAXFrameIO(),
        settle: @escaping (TimeInterval) -> Void = { interval in
            Thread.sleep(forTimeInterval: interval)
        },
        diagnostic: @escaping (String) -> Void = { ArcKitLog.append($0) }
    ) {
        self.io = io
        self.settle = settle
        self.diagnostic = diagnostic
    }

    func frame(of window: AXUIElement, deadline: Date = .distantFuture) throws -> CGRect {
        var lastError: Error?
        for attempt in 0..<4 {
            guard Date() < deadline else { throw CancellationError() }
            do {
                return try io.frame(of: window)
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                // 退出全屏显示后 AXFullScreen 会先变为 false，位置和尺寸可能稍后才恢复可读。
                diagnostic("window ax frame read retry attempt=\(attempt + 1) error=\(error.localizedDescription)")
                settle(0.08)
            }
        }
        throw lastError ?? WindowManagementExecutionError.unreadableWindow
    }

    func setFrame(_ targetFrame: CGRect, for window: AXUIElement, deadline: Date = .distantFuture) throws {
        guard Date() < deadline else { throw CancellationError() }
        let initialFrame = try io.frame(of: window)
        diagnostic(
            "window ax frame write stage=begin target=\(description(targetFrame)) actual=\(description(initialFrame))"
        )

        try writePosition(targetFrame.origin, for: window, stage: "position-initial", deadline: deadline)
        settle(0.06)
        try writeSize(targetFrame.size, for: window, stage: "size-initial", deadline: deadline)
        settle(0.12)
        try writePosition(targetFrame.origin, for: window, stage: "position-after-size", deadline: deadline)
        settle(0.06)

        let firstPassFrame = try io.frame(of: window)
        let needsCorrection = !framesMatch(firstPassFrame, targetFrame)
        diagnostic(
            "window ax frame write stage=first-pass actual=\(description(firstPassFrame)) target=\(description(targetFrame)) correction=\(needsCorrection)"
        )
        guard needsCorrection else { return }

        // AppKit 可能在 AXSize 生效后再次改写 AXPosition；二次校正必须保持 size → position 顺序。
        try writeSize(targetFrame.size, for: window, stage: "size-correction", deadline: deadline)
        settle(0.16)
        try writePosition(targetFrame.origin, for: window, stage: "position-final", deadline: deadline)
        settle(0.08)

        let finalFrame = try io.frame(of: window)
        diagnostic(
            "window ax frame write stage=final actual=\(description(finalFrame)) target=\(description(targetFrame))"
        )
    }

    private func writePosition(_ position: CGPoint, for window: AXUIElement, stage: String, deadline: Date) throws {
        guard Date() < deadline else { throw CancellationError() }
        let result = io.setPosition(position, for: window)
        diagnostic("window ax frame write stage=\(stage) axError=\(result.rawValue)")
        guard result != .success else { return }
        let actualFrame = try io.frame(of: window)
        if originsMatch(actualFrame.origin, position) {
            diagnostic(
                "window ax frame write stage=\(stage) tolerated=true actual=\(description(actualFrame)) reason=position-already-applied"
            )
            return
        }

        settle(0.04)
        guard Date() < deadline else { throw CancellationError() }
        let retryResult = io.setPosition(position, for: window)
        diagnostic("window ax frame write stage=\(stage)-retry axError=\(retryResult.rawValue)")
        guard retryResult == .success else {
            let retryFrame = try io.frame(of: window)
            if originsMatch(retryFrame.origin, position) {
                diagnostic(
                    "window ax frame write stage=\(stage)-retry tolerated=true actual=\(description(retryFrame)) reason=position-already-applied"
                )
                return
            }
            throw WindowManagementExecutionError.unwritableWindow
        }
    }

    private func writeSize(_ size: CGSize, for window: AXUIElement, stage: String, deadline: Date) throws {
        guard Date() < deadline else { throw CancellationError() }
        let result = io.setSize(size, for: window)
        diagnostic("window ax frame write stage=\(stage) axError=\(result.rawValue)")
        guard result != .success else { return }
        let actualFrame = try io.frame(of: window)
        if sizesMatch(actualFrame.size, size) {
            diagnostic(
                "window ax frame write stage=\(stage) tolerated=true actual=\(description(actualFrame)) reason=size-already-applied"
            )
            return
        }

        settle(0.04)
        guard Date() < deadline else { throw CancellationError() }
        let retryResult = io.setSize(size, for: window)
        diagnostic("window ax frame write stage=\(stage)-retry axError=\(retryResult.rawValue)")
        guard retryResult == .success else {
            let retryFrame = try io.frame(of: window)
            if sizesMatch(retryFrame.size, size) {
                diagnostic(
                    "window ax frame write stage=\(stage)-retry tolerated=true actual=\(description(retryFrame)) reason=size-already-applied"
                )
                return
            }
            throw WindowManagementExecutionError.unwritableWindow
        }
    }

    private func framesMatch(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 2) -> Bool {
        originsMatch(actual.origin, expected.origin, tolerance: tolerance)
            && sizesMatch(actual.size, expected.size, tolerance: tolerance)
    }

    private func originsMatch(_ actual: CGPoint, _ expected: CGPoint, tolerance: CGFloat = 2) -> Bool {
        abs(actual.x - expected.x) <= tolerance && abs(actual.y - expected.y) <= tolerance
    }

    private func sizesMatch(_ actual: CGSize, _ expected: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(actual.width - expected.width) <= tolerance && abs(actual.height - expected.height) <= tolerance
    }

    private func description(_ frame: CGRect) -> String {
        "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
    }
}
