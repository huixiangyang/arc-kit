import ArcKitPlatform
import Foundation

public struct MouseScrollModifierState: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = MouseScrollModifierState(rawValue: 1 << 0)
    public static let option = MouseScrollModifierState(rawValue: 1 << 1)
    public static let control = MouseScrollModifierState(rawValue: 1 << 2)
    public static let command = MouseScrollModifierState(rawValue: 1 << 3)
    private static let allowedRawValue = shift.rawValue | option.rawValue | control.rawValue | command.rawValue

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        guard rawValue >= 0, rawValue & ~Self.allowedRawValue == 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: L10n.string(.Mouse.scrollMouseScrollModifierContainsUnknownBits)
            )
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func contains(_ gesture: MouseModifierGesture) -> Bool {
        switch gesture {
        case .none: false
        case .shift: self.intersection(.shift) == .shift
        case .option: self.intersection(.option) == .option
        case .control: self.intersection(.control) == .control
        case .command: self.intersection(.command) == .command
        }
    }
}

public enum MouseScrollInputKind: Equatable, Sendable {
    /// 传统滚轮的离散刻度，需要用最小步长补足 macOS 上的原始滚动距离。
    case discreteWheel
    /// 高分辨率鼠标可能标记 continuous，但不带触控手势 phase。
    /// 这类输入必须平滑，且不能把每个微小脉冲放大成一个完整刻度。
    case highResolutionWheel
    /// 触控板和 Magic Mouse 自带 scroll / momentum phase，必须交还系统处理。
    case nativeGesture
}

/// 所有 delta 均为像素单位，系统事件的行数必须先在 Runtime 转换。
public struct MouseScrollInput: Equatable, Sendable {
    public var verticalDelta: Double
    public var horizontalDelta: Double
    public var kind: MouseScrollInputKind
    public var modifiers: MouseScrollModifierState

    public init(
        verticalDelta: Double,
        horizontalDelta: Double = 0,
        kind: MouseScrollInputKind = .discreteWheel,
        modifiers: MouseScrollModifierState = []
    ) {
        self.verticalDelta = verticalDelta
        self.horizontalDelta = horizontalDelta
        self.kind = kind
        self.modifiers = modifiers
    }
}

public struct MouseScrollImpulse: Equatable, Sendable {
    public var verticalDelta: Double
    public var horizontalDelta: Double
    public var responseTimeMs: Int

    public init(verticalDelta: Double, horizontalDelta: Double, responseTimeMs: Int) {
        self.verticalDelta = verticalDelta
        self.horizontalDelta = horizontalDelta
        self.responseTimeMs = responseTimeMs
    }
}

public enum MouseScrollTransformResult: Equatable, Sendable {
    case passthrough
    case direct(verticalDelta: Double, horizontalDelta: Double)
    case smooth(MouseScrollImpulse)
}

public enum MouseScrollMode: String, Codable, Equatable, Sendable {
    case passthrough
    case direct
    case smooth
}

public struct MouseScrollEngine: Sendable {
    public init() {}

    public func transform(
        input: MouseScrollInput,
        settings: MouseEnhancementSettings,
        appBundleID: String?
    ) -> MouseScrollTransformResult {
        guard input.kind != .nativeGesture,
              let tuning = settings.effectiveTuning(for: appBundleID)
        else {
            return .passthrough
        }

        guard tuning.hasValidModifierAssignments, tuning.hasValidRuntimeValues else {
            return .passthrough
        }
        let accelerated = input.modifiers.contains(tuning.accelerationModifier)
        let horizontal = input.modifiers.contains(tuning.horizontalModifier)
        let smoothDisabled = input.modifiers.contains(tuning.disableSmoothModifier)
        let multiplier = tuning.speedGain * (accelerated ? tuning.accelerationMultiplier : 1)
        let direction = tuning.reverseVertical ? -1.0 : 1.0
        let baseVertical = Self.normalized(
            input.verticalDelta,
            minimumStep: tuning.stepLength,
            kind: input.kind
        ) * multiplier * direction
        let baseHorizontal = Self.normalized(
            input.horizontalDelta,
            minimumStep: tuning.stepLength,
            kind: input.kind
        ) * multiplier

        let outputVertical = horizontal ? 0 : baseVertical
        // Shift 输入可能已被系统换到横轴，两种输入都必须遵守反转设置。
        let outputHorizontal = horizontal ? baseVertical + baseHorizontal * direction : baseHorizontal
        guard outputVertical != 0 || outputHorizontal != 0 else {
            return .passthrough
        }

        guard tuning.smoothEnabled, !smoothDisabled else {
            return .direct(verticalDelta: outputVertical, horizontalDelta: outputHorizontal)
        }
        return .smooth(
            MouseScrollImpulse(
                verticalDelta: outputVertical,
                horizontalDelta: outputHorizontal,
                responseTimeMs: tuning.responseTimeMs
            )
        )
    }

    private static func normalized(
        _ value: Double,
        minimumStep: Double,
        kind: MouseScrollInputKind
    ) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        if kind == .highResolutionWheel {
            return value
        }
        return value.sign == .minus ? -max(abs(value), minimumStep) : max(abs(value), minimumStep)
    }
}
