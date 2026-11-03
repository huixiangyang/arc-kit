import ArcKitPlatform
import ArcKitWindow
import SwiftUI

/// 窗口动作仍拥有自己的启用意图；录制控件只编辑共用的按键组合。
struct WindowHotKeyRecorder: View {
    @Binding var binding: WindowHotKeyBinding
    var duplicateShortcuts: Set<String>

    var body: some View {
        KeyboardShortcutRecorder(binding: Binding(
            get: { HotKeyChord(keyCode: binding.keyCode, keyEquivalent: binding.keyEquivalent,
                modifiers: .init(rawValue: binding.modifiers.rawValue), isEnabled: binding.isEnabled) },
            set: { value in
                binding.keyCode = value.keyCode
                binding.keyEquivalent = value.keyEquivalent
                binding.modifiers = WindowHotKeyModifier(rawValue: value.modifiers.rawValue)
                binding.isEnabled = value.isEnabled
            }
        ), duplicateShortcuts: duplicateShortcuts)
    }
}
