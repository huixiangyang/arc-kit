import ArcKitPlatform
import Foundation

public struct MouseGestureSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var triggerButton: MouseGestureTriggerButton
    public var minimumDistance: Double
    public var showVisualHint: Bool
    public var bindings: [MouseGestureBinding]

    public init(
        isEnabled: Bool = false,
        triggerButton: MouseGestureTriggerButton = .rightButton,
        minimumDistance: Double = 80,
        showVisualHint: Bool = true,
        bindings: [MouseGestureBinding] = MouseGestureBinding.defaults
    ) {
        self.isEnabled = isEnabled
        self.triggerButton = triggerButton
        self.minimumDistance = minimumDistance
        self.showVisualHint = showVisualHint
        self.bindings = bindings
    }

    public static let defaults = MouseGestureSettings()

    enum CodingKeys: String, CodingKey {
        case isEnabled, triggerButton, minimumDistance, showVisualHint, bindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMinimumDistance = try container.decode(Double.self, forKey: .minimumDistance)
        guard decodedMinimumDistance.isFinite, decodedMinimumDistance >= 40, decodedMinimumDistance <= 180 else {
            throw DecodingError.dataCorruptedError(
                forKey: .minimumDistance,
                in: container,
                debugDescription: L10n.string(.Mouse.gestureMouseGestureDistanceOutsideCurrent)
            )
        }
        let decodedBindings = try container.decode([MouseGestureBinding].self, forKey: .bindings)
        try Self.validateBindings(decodedBindings)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        triggerButton = try container.decode(MouseGestureTriggerButton.self, forKey: .triggerButton)
        minimumDistance = decodedMinimumDistance
        showVisualHint = try container.decode(Bool.self, forKey: .showVisualHint)
        bindings = decodedBindings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(triggerButton, forKey: .triggerButton)
        try container.encode(minimumDistance, forKey: .minimumDistance)
        try container.encode(showVisualHint, forKey: .showVisualHint)
        try container.encode(bindings, forKey: .bindings)
    }

    public func action(for direction: MouseGestureDirection) -> MouseGestureAction {
        bindings.first { $0.direction == direction }?.action ?? .none
    }

    private static func validateBindings(_ bindings: [MouseGestureBinding]) throws {
        let directions = bindings.map(\.direction)
        let expected = Set(MouseGestureDirection.allCases)
        guard Set(directions) == expected, directions.count == expected.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.bindings],
                debugDescription: L10n.string(.Mouse.gestureMouseGestureBindingsCoverEveryDirection)
            ))
        }
    }
}

public enum MouseGestureTriggerButton: String, Codable, CaseIterable, Sendable {
    case rightButton
    public var displayName: String { L10n.string(.Mouse.gestureHoldRightButtonDrag) }
}

public struct MouseGestureBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: MouseGestureDirection { direction }
    public var direction: MouseGestureDirection
    public var action: MouseGestureAction

    public init(direction: MouseGestureDirection, action: MouseGestureAction) {
        self.direction = direction
        self.action = action
    }

    public static let defaults: [MouseGestureBinding] = [
        MouseGestureBinding(direction: .left, action: .navigateBack),
        MouseGestureBinding(direction: .right, action: .navigateForward),
        MouseGestureBinding(direction: .up, action: .missionControl),
        MouseGestureBinding(direction: .down, action: .showDesktop),
    ]
}

public enum MouseGestureDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var displayName: String {
        switch self {
        case .left: L10n.string(.Mouse.gestureLeft)
        case .right: L10n.string(.Mouse.gestureRight)
        case .up: L10n.string(.Mouse.gestureUp)
        case .down: L10n.string(.Mouse.gestureDown)
        }
    }
}

public enum MouseGestureAction: String, Codable, CaseIterable, Sendable {
    case none
    case navigateBack
    case navigateForward
    case missionControl
    case showDesktop
    case applicationWindows

    public var displayName: String {
        switch self {
        case .none: L10n.string(.Mouse.gestureActionMissing)
        case .navigateBack: L10n.string(.Mouse.gestureBack)
        case .navigateForward: L10n.string(.Mouse.gestureForward)
        case .missionControl: L10n.string(.Mouse.gestureMissionControl)
        case .showDesktop: L10n.string(.Mouse.gestureShowDesktop)
        case .applicationWindows: L10n.string(.Mouse.gestureAppWindows)
        }
    }
}

public struct MouseGestureInput: Equatable, Sendable {
    public var startX: Double
    public var startY: Double
    public var currentX: Double
    public var currentY: Double

    public init(startX: Double, startY: Double, currentX: Double, currentY: Double) {
        self.startX = startX
        self.startY = startY
        self.currentX = currentX
        self.currentY = currentY
    }
}

public struct MouseGestureRecognitionResult: Equatable, Sendable {
    public var direction: MouseGestureDirection
    public var action: MouseGestureAction
    public var distance: Double

    public init(direction: MouseGestureDirection, action: MouseGestureAction, distance: Double) {
        self.direction = direction
        self.action = action
        self.distance = distance
    }
}

public enum MouseGestureDecision: Equatable, Sendable {
    case disabled
    case belowThreshold(distance: Double)
    case noAction(direction: MouseGestureDirection, distance: Double)
    case execute(MouseGestureRecognitionResult)

    public var shouldRepostRightClick: Bool {
        switch self {
        case .disabled, .belowThreshold, .noAction: true
        case .execute: false
        }
    }

    public var result: MouseGestureRecognitionResult? {
        if case let .execute(result) = self { return result }
        return nil
    }
}

/// 手势引擎只做方向与阈值决策；EventTap 拦截和右键回放仍由 AppSupport 负责。
public struct MouseGestureEngine: Sendable {
    public init() {}

    public func recognize(
        input: MouseGestureInput,
        settings: MouseGestureSettings
    ) -> MouseGestureRecognitionResult? {
        decide(input: input, settings: settings).result
    }

    public func decide(input: MouseGestureInput, settings: MouseGestureSettings) -> MouseGestureDecision {
        guard settings.isEnabled else { return .disabled }
        let deltaX = input.currentX - input.startX
        let deltaY = input.currentY - input.startY
        let distance = hypot(deltaX, deltaY)
        guard distance >= settings.minimumDistance else { return .belowThreshold(distance: distance) }

        let direction: MouseGestureDirection
        if abs(deltaX) >= abs(deltaY) {
            direction = deltaX < 0 ? .left : .right
        } else {
            // CGEvent location 的 y 轴向下增大，因此负数代表鼠标向上拖动。
            direction = deltaY < 0 ? .up : .down
        }
        let action = settings.action(for: direction)
        guard action != .none else { return .noAction(direction: direction, distance: distance) }
        return .execute(MouseGestureRecognitionResult(direction: direction, action: action, distance: distance))
    }
}
