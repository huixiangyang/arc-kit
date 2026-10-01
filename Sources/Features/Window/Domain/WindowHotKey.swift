import ArcKitPlatform
import Foundation

public struct WindowHotKeyModifier: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = WindowHotKeyModifier(rawValue: 1 << 0)
    public static let option = WindowHotKeyModifier(rawValue: 1 << 1)
    public static let command = WindowHotKeyModifier(rawValue: 1 << 2)
    public static let shift = WindowHotKeyModifier(rawValue: 1 << 3)
    private static let allowedRawValue = control.rawValue | option.rawValue | command.rawValue | shift.rawValue

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        guard rawValue >= 0, rawValue & ~Self.allowedRawValue == 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.string(.Window.shortcutWindowShortcutModifierContainsUnknownBits))
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    public var containsPrimaryModifier: Bool {
        contains(.control) || contains(.option) || contains(.command)
    }
}

public struct WindowHotKeyBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: WindowLayoutAction { action }
    public var action: WindowLayoutAction
    public var keyCode: UInt16
    public var keyEquivalent: String
    public var modifiers: WindowHotKeyModifier
    public var isEnabled: Bool

    public init(
        action: WindowLayoutAction,
        keyCode: UInt16,
        keyEquivalent: String,
        modifiers: WindowHotKeyModifier = [.control, .option],
        isEnabled: Bool = true
    ) {
        self.action = action
        self.keyCode = keyCode
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case action, keyCode, keyEquivalent, modifiers, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(WindowLayoutAction.self, forKey: .action)
        let decodedKeyCode = try container.decode(UInt16.self, forKey: .keyCode)
        guard Self.isValidKeyCode(decodedKeyCode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: container,
                debugDescription: L10n.string(.Window.shortcutWindowShortcutKeycodeOutsideSupported)
            )
        }
        keyCode = decodedKeyCode
        let decodedKeyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        guard Self.isValidKeyEquivalent(decodedKeyEquivalent) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyEquivalent,
                in: container,
                debugDescription: L10n.string(.Window.shortcutWindowShortcutDisplayValueOne)
            )
        }
        keyEquivalent = decodedKeyEquivalent
        modifiers = try container.decode(WindowHotKeyModifier.self, forKey: .modifiers)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    public var displayShortcut: String { "\(modifiers.displayName)\(keyEquivalent)" }
    public var shortcutIdentifier: String { "\(modifiers.rawValue):\(keyCode)" }

    public var isSafeGlobalShortcut: Bool {
        isEnabled
            && Self.isValidKeyCode(keyCode)
            && Self.isValidKeyEquivalent(keyEquivalent)
            && modifiers.containsPrimaryModifier
    }

    public static func isValidKeyCode(_ value: UInt16) -> Bool {
        // Carbon RegisterEventHotKey 使用 macOS 虚拟键码；坏配置直接拒绝，不在运行时假注册。
        value <= 127
    }

    public static func isValidKeyEquivalent(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        if namedKeyEquivalents.contains(value) { return true }
        guard value.count == 1, let scalar = value.unicodeScalars.first else { return false }
        return scalar.value >= 33 && scalar.value <= 126
    }

    private static let namedKeyEquivalents: Set<String> = [
        "↩", "⇥", "⌤", "Home", "PgUp", "End", "PgDn", "←", "→", "↓", "↑", "Space",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ]

    public static let magnetDefaults: [WindowHotKeyBinding] = [
        WindowHotKeyBinding(action: .leftHalf, keyCode: 123, keyEquivalent: "←"),
        WindowHotKeyBinding(action: .rightHalf, keyCode: 124, keyEquivalent: "→"),
        WindowHotKeyBinding(action: .topHalf, keyCode: 126, keyEquivalent: "↑"),
        WindowHotKeyBinding(action: .bottomHalf, keyCode: 125, keyEquivalent: "↓"),
        WindowHotKeyBinding(action: .topLeft, keyCode: 0, keyEquivalent: "A"),
        WindowHotKeyBinding(action: .topRight, keyCode: 2, keyEquivalent: "D"),
        WindowHotKeyBinding(action: .bottomLeft, keyCode: 1, keyEquivalent: "S"),
        WindowHotKeyBinding(action: .bottomRight, keyCode: 13, keyEquivalent: "W"),
        WindowHotKeyBinding(action: .leftThird, keyCode: 18, keyEquivalent: "1"),
        WindowHotKeyBinding(action: .centerThird, keyCode: 19, keyEquivalent: "2"),
        WindowHotKeyBinding(action: .rightThird, keyCode: 20, keyEquivalent: "3"),
        WindowHotKeyBinding(action: .leftTwoThirds, keyCode: 21, keyEquivalent: "4"),
        WindowHotKeyBinding(action: .rightTwoThirds, keyCode: 23, keyEquivalent: "5"),
        WindowHotKeyBinding(action: .fullScreen, keyCode: 36, keyEquivalent: "↩"),
        WindowHotKeyBinding(action: .center, keyCode: 8, keyEquivalent: "C"),
        WindowHotKeyBinding(action: .fill, keyCode: 3, keyEquivalent: "F"),
        WindowHotKeyBinding(action: .nextDisplay, keyCode: 47, keyEquivalent: "."),
        WindowHotKeyBinding(action: .previousDisplay, keyCode: 43, keyEquivalent: ","),
        WindowHotKeyBinding(action: .restore, keyCode: 15, keyEquivalent: "R"),
    ]
}

public struct WindowHotKeyRegistrationPlan: Equatable, Sendable {
    public var validBindings: [WindowHotKeyBinding]
    public var unsafeBindings: [WindowHotKeyBinding]
    public var duplicateBindings: [WindowHotKeyBinding]

    public init(
        validBindings: [WindowHotKeyBinding],
        unsafeBindings: [WindowHotKeyBinding],
        duplicateBindings: [WindowHotKeyBinding]
    ) {
        self.validBindings = validBindings
        self.unsafeBindings = unsafeBindings
        self.duplicateBindings = duplicateBindings
    }
}
