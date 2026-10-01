import Foundation

/// Runtime 标记自产滚轮，应用内诊断可据此区分系统输入与增强输出。
public enum MouseScrollEventOrigin {
    public static let syntheticMarker: Int64 = 0x4152434B49544D53
}

/// 只记录计数与事件目标，不记录页面内容、鼠标位置或原始事件。
public struct MouseScrollDiagnostics: Codable, Equatable, Sendable {
    public var wheelInputs = 0
    public var nativeGestureInputs = 0
    public var bypassedInputs = 0
    public var targetProcessID: Int32 = 0
    public var targetWindowAvailable = false
    public var targetBundleIdentifier: String?
    public var output = MouseScrollOutputStatistics()
    public init() {}
}

public struct MouseScrollOutputStatistics: Codable, Equatable, Sendable {
    public var generatedEvents = 0
    public var postedFrames = 0
    public var verticalPixels: Int64 = 0
    public var horizontalPixels: Int64 = 0
    public var directFallbacks = 0
    public var creationFailures = 0
    public init() {}
}
