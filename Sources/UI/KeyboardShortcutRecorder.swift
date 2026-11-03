import ArcKitPlatform
@preconcurrency import AppKit
import SwiftUI

struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var binding: HotKeyChord
    var duplicateShortcuts: Set<String>
    var rejectDuplicates = false
    var onRecordingChange: ((UUID, Bool) -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> KeyboardShortcutRecorderControl {
        let view = KeyboardShortcutRecorderControl()
        view.onRecordingChange = onRecordingChange
        view.onChange = { value in
            binding = value
        }
        view.configure(binding: binding, duplicateShortcuts: duplicateShortcuts, rejectDuplicates: rejectDuplicates, isEnabled: isEnabled)
        return view
    }

    func updateNSView(_ nsView: KeyboardShortcutRecorderControl, context: Context) {
        nsView.onRecordingChange = onRecordingChange
        nsView.onChange = { value in
            binding = value
        }
        nsView.configure(binding: binding, duplicateShortcuts: duplicateShortcuts, rejectDuplicates: rejectDuplicates, isEnabled: isEnabled)
    }

    static func dismantleNSView(_ nsView: KeyboardShortcutRecorderControl, coordinator: ()) {
        _ = nsView.resignFirstResponder()
        nsView.onRecordingChange = nil
    }
}

final class KeyboardShortcutRecorderControl: NSView {
    var onChange: ((HotKeyChord) -> Void)?
    var onRecordingChange: ((UUID, Bool) -> Void)?
    private let recordingID = UUID()

    private var binding: HotKeyChord?
    private var duplicateShortcuts: Set<String> = []
    private var isRecording = false {
        didSet { if oldValue != isRecording { onRecordingChange?(recordingID, isRecording) } }
    }
    private var rejectDuplicates = false
    private var allowsRecording = true
    private var validationMessage: String?
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.string(.Common.shortcutRecorderLabel))
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { allowsRecording }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    func configure(binding: HotKeyChord, duplicateShortcuts: Set<String>, rejectDuplicates: Bool = false, isEnabled: Bool = true) {
        self.rejectDuplicates = rejectDuplicates
        allowsRecording = isEnabled
        if !isEnabled { isRecording = false; validationMessage = nil }
        self.binding = binding
        self.duplicateShortcuts = duplicateShortcuts
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    private func beginRecording() {
        guard allowsRecording, binding != nil else { return }
        isRecording = true
        validationMessage = nil
        window?.makeFirstResponder(self)
        updateAppearance()
    }

    override func accessibilityPerformPress() -> Bool {
        guard allowsRecording else { return false }; beginRecording(); return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, allowsRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        validationMessage = nil
        updateAppearance()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard allowsRecording else { return }
        guard isRecording else {
            if event.keyCode == 36 || event.keyCode == 49 { beginRecording() }
            else { super.keyDown(with: event) }
            return
        }
        guard var binding else { return }
        if event.keyCode == 53 {
            isRecording = false
            validationMessage = nil
            updateAppearance()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            binding.isEnabled = false
            isRecording = false
            validationMessage = nil
            self.binding = binding
            onChange?(binding)
            updateAppearance()
            return
        }
        guard !Self.modifierOnlyKeyCodes.contains(event.keyCode) else {
            return
        }
        guard HotKeyChord.isValidKeyCode(event.keyCode) else {
            validationMessage = L10n.string(.Common.shortcutRecorderUnsupportedKey)
            updateAppearance()
            return
        }
        let modifiers = HotKeyChord.Modifiers(eventModifierFlags: event.modifierFlags)
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else {
            validationMessage = L10n.string(.Common.shortcutRecorderRequires)
            updateAppearance()
            return
        }
        guard let keyEquivalent = Self.keyEquivalent(for: event) else {
            validationMessage = L10n.string(.Common.shortcutRecorderUnsupportedKey)
            updateAppearance()
            return
        }
        guard HotKeyChord.isValidKeyEquivalent(keyEquivalent) else {
            validationMessage = L10n.string(.Common.shortcutRecorderUnsupportedKey)
            updateAppearance()
            return
        }
        binding.keyCode = event.keyCode
        binding.keyEquivalent = keyEquivalent
        binding.modifiers = modifiers
        guard !rejectDuplicates || !duplicateShortcuts.contains(binding.shortcutIdentifier) else {
            validationMessage = L10n.string(.Common.shortcutRecorderDuplicate)
            updateAppearance()
            return
        }
        binding.isEnabled = true
        isRecording = false
        validationMessage = nil
        self.binding = binding
        onChange?(binding)
        updateAppearance()
    }

    private func updateAppearance() {
        let isDuplicate = binding.map { duplicateShortcuts.contains($0.shortcutIdentifier) } ?? false
        label.stringValue = displayText
        setAccessibilityValue(displayText)
        toolTip = validationMessage ?? L10n.string(.Common.shortcutRecorderHint)
        label.textColor = isRecording ? .controlAccentColor : (isDuplicate || validationMessage != nil ? .systemOrange : .labelColor)
        layer?.cornerRadius = 7
        layer?.borderWidth = isRecording ? 1.5 : 1
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : (isDuplicate || validationMessage != nil ? .systemOrange : .separatorColor)).cgColor
        layer?.backgroundColor = (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor.withAlphaComponent(0.45)).cgColor
    }

    private var displayText: String {
        if let validationMessage {
            return validationMessage
        }
        if isRecording {
            return L10n.string(.Common.shortcutRecorderPressShortcut)
        }
        guard let binding else {
            return "-"
        }
        if !binding.isEnabled, !binding.modifiers.containsPrimaryModifier { return L10n.string(.Common.shortcutRecorderClickRecord) }
        return binding.isEnabled ? binding.displayShortcut : L10n.string(.Common.shortcutRecorderDisabled)
    }

    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static func keyEquivalent(for event: NSEvent) -> String? {
        if let special = specialKeyNames[event.keyCode] {
            return special
        }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let characters, !characters.isEmpty else {
            return nil
        }
        return characters.uppercased()
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩",
        48: "⇥",
        49: "Space",
        76: "⌤",
        115: "Home",
        116: "PgUp",
        119: "End",
        121: "PgDn",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
    ]
}

private extension HotKeyChord.Modifiers {
    init(eventModifierFlags: NSEvent.ModifierFlags) {
        var modifiers: HotKeyChord.Modifiers = []
        if eventModifierFlags.contains(.control) { modifiers.insert(.control) }
        if eventModifierFlags.contains(.option) { modifiers.insert(.option) }
        if eventModifierFlags.contains(.command) { modifiers.insert(.command) }
        if eventModifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
