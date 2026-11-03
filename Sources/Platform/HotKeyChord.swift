import Foundation

/// 与具体功能无关的按键组合；虚拟键码用于注册，显示名只用于界面。
public struct HotKeyChord: Codable, Equatable, Sendable {
    public struct Modifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1 << 0)
        public static let option = Self(rawValue: 1 << 1)
        public static let command = Self(rawValue: 1 << 2)
        public static let shift = Self(rawValue: 1 << 3)
        public var containsPrimaryModifier: Bool { !intersection([.control, .option, .command]).isEmpty }
        public var displayName: String {
            [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { contains($0.0) }.map(\.1).joined()
        }
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)
            guard value >= 0, value & ~15 == 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: L10n.string(.Common.shortcutInvalid))
            }
            self.init(rawValue: value)
        }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer(); try container.encode(rawValue)
        }
    }
    public var keyCode: UInt16
    public var keyEquivalent: String
    public var modifiers: Modifiers
    public var isEnabled: Bool
    public static let disabled = Self(keyCode: 46, keyEquivalent: "M", modifiers: [], isEnabled: false)

    public init(keyCode: UInt16, keyEquivalent: String, modifiers: Modifiers, isEnabled: Bool = true) {
        self.keyCode = keyCode; self.keyEquivalent = keyEquivalent; self.modifiers = modifiers; self.isEnabled = isEnabled
    }
    public var displayShortcut: String { modifiers.displayName + keyEquivalent }
    public var shortcutIdentifier: String { "\(modifiers.rawValue):\(keyCode)" }
    public var isSafeGlobalShortcut: Bool {
        isEnabled && Self.isValidKeyCode(keyCode) && Self.isValidKeyEquivalent(keyEquivalent)
            && modifiers.rawValue >= 0 && modifiers.rawValue & ~15 == 0 && modifiers.containsPrimaryModifier
    }
    public static func isValidKeyCode(_ value: UInt16) -> Bool { value <= 127 }
    public static func isValidKeyEquivalent(_ value: String) -> Bool {
        if namedKeys.contains(value) { return true }
        guard value.count == 1, let scalar = value.unicodeScalars.first else { return false }
        return scalar.value >= 33 && scalar.value <= 126
    }
    private static let namedKeys: Set<String> = [
        "↩", "⇥", "⌤", "Home", "PgUp", "End", "PgDn", "←", "→", "↓", "↑", "Space",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
    ]
    private enum CodingKeys: String, CodingKey { case keyCode, keyEquivalent, modifiers, isEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        keyEquivalent = try c.decode(String.self, forKey: .keyEquivalent)
        modifiers = try c.decode(Modifiers.self, forKey: .modifiers)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        guard Self.isValidKeyCode(keyCode), Self.isValidKeyEquivalent(keyEquivalent), !isEnabled || modifiers.containsPrimaryModifier else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: c, debugDescription: L10n.string(.Common.shortcutInvalid))
        }
    }
}
