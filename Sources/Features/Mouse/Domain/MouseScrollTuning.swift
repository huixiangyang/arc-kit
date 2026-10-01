import ArcKitPlatform
import Foundation

public struct MouseScrollTuning: Codable, Equatable, Sendable {
    public var smoothEnabled: Bool
    public var reverseVertical: Bool
    public var responseTimeMs: Int
    public var speedGain: Double
    public var stepLength: Double
    public var accelerationMultiplier: Double
    public var horizontalModifier: MouseModifierGesture
    public var accelerationModifier: MouseModifierGesture
    public var disableSmoothModifier: MouseModifierGesture

    public init(
        smoothEnabled: Bool = true,
        reverseVertical: Bool = true,
        responseTimeMs: Int = 180,
        speedGain: Double = 2.7,
        stepLength: Double = 34,
        accelerationMultiplier: Double = 3.0,
        horizontalModifier: MouseModifierGesture = .shift,
        accelerationModifier: MouseModifierGesture = .option,
        disableSmoothModifier: MouseModifierGesture = .control
    ) {
        self.smoothEnabled = smoothEnabled
        self.reverseVertical = reverseVertical
        self.responseTimeMs = responseTimeMs
        self.speedGain = speedGain
        self.stepLength = stepLength
        self.accelerationMultiplier = accelerationMultiplier
        self.horizontalModifier = horizontalModifier
        self.accelerationModifier = accelerationModifier
        self.disableSmoothModifier = disableSmoothModifier
    }

    public static let defaults = MouseScrollTuning()

    public var hasValidModifierAssignments: Bool {
        let activeModifiers = MouseScrollModifierRole.allCases.compactMap { role in
            let modifier = modifier(for: role)
            return modifier == .none ? nil : modifier
        }
        return Set(activeModifiers).count == activeModifiers.count
    }

    public var hasValidRuntimeValues: Bool {
        (80...320).contains(responseTimeMs)
            && speedGain.isFinite && (0.5...3.0).contains(speedGain)
            && stepLength.isFinite && (16...120).contains(stepLength)
            && accelerationMultiplier.isFinite && (1.5...6.0).contains(accelerationMultiplier)
    }

    public func modifier(for role: MouseScrollModifierRole) -> MouseModifierGesture {
        switch role {
        case .horizontalScroll:
            horizontalModifier
        case .acceleratedScroll:
            accelerationModifier
        case .disableSmoothScroll:
            disableSmoothModifier
        }
    }

    /// 一个修饰键只能触发一种滚动动作；重新分配时立即清空旧归属，避免运行时产生组合歧义。
    @discardableResult
    public mutating func assignModifier(
        _ modifier: MouseModifierGesture,
        to role: MouseScrollModifierRole
    ) -> [MouseScrollModifierRole] {
        setModifier(modifier, for: role)
        guard modifier != .none else { return [] }

        var clearedRoles: [MouseScrollModifierRole] = []
        for otherRole in MouseScrollModifierRole.allCases where otherRole != role {
            guard self.modifier(for: otherRole) == modifier else { continue }
            setModifier(.none, for: otherRole)
            clearedRoles.append(otherRole)
        }
        return clearedRoles
    }

    enum CodingKeys: String, CodingKey {
        case smoothEnabled
        case reverseVertical
        case responseTimeMs
        case speedGain
        case stepLength
        case accelerationMultiplier
        case horizontalModifier
        case accelerationModifier
        case disableSmoothModifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedResponseTime = try container.decode(Int.self, forKey: .responseTimeMs)
        guard (80...320).contains(decodedResponseTime) else {
            throw DecodingError.dataCorruptedError(
                forKey: .responseTimeMs,
                in: container,
                debugDescription: L10n.string(.Mouse.tuningMouseInertiaResponseTimeOutside)
            )
        }
        let decodedSpeedGain = try container.decode(Double.self, forKey: .speedGain)
        try Self.validate(decodedSpeedGain, key: .speedGain, in: container, range: 0.5...3.0, name: L10n.string(.Mouse.tuningMouseSpeedGain))
        let decodedStepLength = try container.decode(Double.self, forKey: .stepLength)
        try Self.validate(decodedStepLength, key: .stepLength, in: container, range: 16...120, name: L10n.string(.Mouse.tuningMouseScrollStep))
        let decodedAccelerationMultiplier = try container.decode(Double.self, forKey: .accelerationMultiplier)
        try Self.validate(decodedAccelerationMultiplier, key: .accelerationMultiplier, in: container, range: 1.5...6.0, name: L10n.string(.Mouse.tuningMouseAccelerationMultiplier))

        smoothEnabled = try container.decode(Bool.self, forKey: .smoothEnabled)
        reverseVertical = try container.decode(Bool.self, forKey: .reverseVertical)
        responseTimeMs = decodedResponseTime
        speedGain = decodedSpeedGain
        stepLength = decodedStepLength
        accelerationMultiplier = decodedAccelerationMultiplier
        horizontalModifier = try container.decode(MouseModifierGesture.self, forKey: .horizontalModifier)
        accelerationModifier = try container.decode(MouseModifierGesture.self, forKey: .accelerationModifier)
        disableSmoothModifier = try container.decode(MouseModifierGesture.self, forKey: .disableSmoothModifier)
        guard hasValidModifierAssignments else {
            throw DecodingError.dataCorruptedError(
                forKey: .horizontalModifier,
                in: container,
                debugDescription: L10n.string(.Mouse.tuningDuplicateModifier)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(smoothEnabled, forKey: .smoothEnabled)
        try container.encode(reverseVertical, forKey: .reverseVertical)
        try container.encode(responseTimeMs, forKey: .responseTimeMs)
        try container.encode(speedGain, forKey: .speedGain)
        try container.encode(stepLength, forKey: .stepLength)
        try container.encode(accelerationMultiplier, forKey: .accelerationMultiplier)
        try container.encode(horizontalModifier, forKey: .horizontalModifier)
        try container.encode(accelerationModifier, forKey: .accelerationModifier)
        try container.encode(disableSmoothModifier, forKey: .disableSmoothModifier)
    }

    private static func validate(
        _ value: Double,
        key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        range: ClosedRange<Double>,
        name: String
    ) throws {
        guard value.isFinite, range.contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: L10n.string(.Mouse.tuningOutsideCurrentSchemaSRange(String(describing: name)))
            )
        }
    }

    private mutating func setModifier(_ modifier: MouseModifierGesture, for role: MouseScrollModifierRole) {
        switch role {
        case .horizontalScroll:
            horizontalModifier = modifier
        case .acceleratedScroll:
            accelerationModifier = modifier
        case .disableSmoothScroll:
            disableSmoothModifier = modifier
        }
    }
}

public enum MouseScrollModifierRole: String, Equatable, CaseIterable, Sendable {
    case horizontalScroll
    case acceleratedScroll
    case disableSmoothScroll

    public var displayName: String {
        switch self {
        case .horizontalScroll: L10n.string(.Mouse.tuningHorizontalScrolling)
        case .acceleratedScroll: L10n.string(.Mouse.tuningTemporaryAcceleration)
        case .disableSmoothScroll: L10n.string(.Mouse.tuningTemporarilyDisableSmoothing)
        }
    }
}

public enum MouseModifierGesture: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case none
    case shift
    case option
    case control
    case command

    public var displayName: String {
        switch self {
        case .none: L10n.string(.Common.none)
        case .shift: "Shift"
        case .option: "Option"
        case .control: "Control"
        case .command: "Command"
        }
    }
}
