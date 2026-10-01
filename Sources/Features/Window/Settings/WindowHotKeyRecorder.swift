import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
@preconcurrency import AppKit
import SwiftUI

struct WindowHotKeyRecorder: NSViewRepresentable {
    @Binding var binding: WindowHotKeyBinding
    var duplicateShortcuts: Set<String>

    func makeNSView(context: Context) -> WindowHotKeyRecorderControl {
        let view = WindowHotKeyRecorderControl()
        view.onChange = { value in
            binding = value
        }
        view.configure(binding: binding, duplicateShortcuts: duplicateShortcuts)
        return view
    }

    func updateNSView(_ nsView: WindowHotKeyRecorderControl, context: Context) {
        nsView.onChange = { value in
            binding = value
        }
        nsView.configure(binding: binding, duplicateShortcuts: duplicateShortcuts)
    }
}

final class WindowHotKeyRecorderControl: NSView {
    var onChange: ((WindowHotKeyBinding) -> Void)?

    private var binding: WindowHotKeyBinding?
    private var duplicateShortcuts: Set<String> = []
    private var isRecording = false
    private var validationMessage: String?
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    func configure(binding: WindowHotKeyBinding, duplicateShortcuts: Set<String>) {
        self.binding = binding
        self.duplicateShortcuts = duplicateShortcuts
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard binding != nil else { return }
        isRecording = true
        validationMessage = nil
        window?.makeFirstResponder(self)
        updateAppearance()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        validationMessage = nil
        updateAppearance()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
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
            onChange?(binding)
            updateAppearance()
            return
        }
        guard !Self.modifierOnlyKeyCodes.contains(event.keyCode) else {
            return
        }
        guard WindowHotKeyBinding.isValidKeyCode(event.keyCode) else {
            validationMessage = L10n.string(.WindowSettings.recorderUnsupportedKey)
            updateAppearance()
            return
        }
        let modifiers = WindowHotKeyModifier(eventModifierFlags: event.modifierFlags)
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else {
            validationMessage = L10n.string(.WindowSettings.recorderRequires)
            updateAppearance()
            return
        }
        guard let keyEquivalent = Self.keyEquivalent(for: event) else {
            validationMessage = L10n.string(.WindowSettings.recorderUnsupportedKey)
            updateAppearance()
            return
        }
        guard WindowHotKeyBinding.isValidKeyEquivalent(keyEquivalent) else {
            validationMessage = L10n.string(.WindowSettings.recorderUnsupportedKey)
            updateAppearance()
            return
        }
        binding.keyCode = event.keyCode
        binding.keyEquivalent = keyEquivalent
        binding.modifiers = modifiers
        binding.isEnabled = true
        isRecording = false
        validationMessage = nil
        onChange?(binding)
        updateAppearance()
    }

    private func updateAppearance() {
        let isDuplicate = binding.map { duplicateShortcuts.contains($0.shortcutIdentifier) } ?? false
        label.stringValue = displayText
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
            return L10n.string(.WindowSettings.recorderPressShortcut)
        }
        guard let binding else {
            return "-"
        }
        if !binding.isEnabled, !binding.modifiers.containsPrimaryModifier { return L10n.string(.WindowSettings.recorderClickRecord) }
        return binding.isEnabled ? binding.displayShortcut : L10n.string(.WindowSettings.recorderDisabled)
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

private extension WindowHotKeyModifier {
    init(eventModifierFlags: NSEvent.ModifierFlags) {
        var modifiers: WindowHotKeyModifier = []
        if eventModifierFlags.contains(.control) { modifiers.insert(.control) }
        if eventModifierFlags.contains(.option) { modifiers.insert(.option) }
        if eventModifierFlags.contains(.command) { modifiers.insert(.command) }
        if eventModifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
