import ArcKitPlatform
import ArcKitMouse
@preconcurrency import AppKit
import SwiftUI

struct MouseScrollingEditor: View {
    @ObservedObject var model: SettingsEditor<MouseEnhancementSettings>
    let editing: MouseScrollEditing
    @State private var showsScrollResetConfirmation = false

    var body: some View {
        Section(L10n.string(.MouseSettings.scrollScrolling)) {
            Toggle(L10n.string(.MouseSettings.scrollSmoothScrolling), isOn: editing.tuningBoolBinding(\.smoothEnabled, actionName: L10n.string(.MouseSettings.scrollToggleSmoothScrolling))
            )
            Toggle(L10n.string(.MouseSettings.scrollReverseScrollDirection), isOn: editing.tuningBoolBinding(\.reverseVertical, actionName: L10n.string(.MouseSettings.scrollToggleScrollDirection))
            )
            MouseSliderRow(title: L10n.string(.MouseSettings.scrollScrollSpeed), value: editing.tuningDoubleBinding(\.speedGain), range: 0.5...3.0, suffix: "×")
            MouseSliderRow(title: L10n.string(.MouseSettings.scrollSmoothingDuration), value: editing.tuningIntBinding(\.responseTimeMs), range: 80...320, suffix: "ms")
                .disabled(!model.settings.globalTuning.smoothEnabled)
                .help(L10n.string(.MouseSettings.scrollLongerDurationsMakeScrollingSlowDownMore))
            if !model.settings.globalTuning.smoothEnabled {
                Text(L10n.string(.MouseSettings.scrollEnableSmoothScrollingAdjustDuration))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                ArcToolbarButton(title: L10n.string(.Common.restoreDefaults), symbol: .arcRefresh) {
                    showsScrollResetConfirmation = true
                }
                .disabled(model.settings.globalTuning == .defaults)
            }

        }
        .confirmationDialog(
            L10n.string(.MouseSettings.scrollRestoreConfirmation),
            isPresented: $showsScrollResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string(.MouseSettings.scrollRestoreDefaultScrollingFeel), role: .destructive, action: editing.resetScrollTuning)
            Button(L10n.string(.Common.cancel), role: .cancel) {}
        } message: {
            Text(L10n.string(.MouseSettings.scrollRestoreHint))
        }
    }

}

struct MouseAdvancedEditor: View {
    @ObservedObject var model: SettingsEditor<MouseEnhancementSettings>
    let editing: MouseScrollEditing
    var body: some View {
        Section(L10n.string(.MouseSettings.scrollModifierKeysFineTuning)) {
            VStack(spacing: 12) {
                MouseModifierPicker(title: L10n.string(.MouseSettings.tuningHorizontalScrolling), selection: editing.tuningModifierBinding(.horizontalScroll))
                MouseModifierPicker(title: L10n.string(.MouseSettings.tuningTemporaryAcceleration), selection: editing.tuningModifierBinding(.acceleratedScroll))
                MouseSliderRow(title: L10n.string(.MouseSettings.scrollAccelerationMultiplier), value: editing.tuningDoubleBinding(\.accelerationMultiplier), range: 1.5...6.0, suffix: "×")
                    .disabled(model.settings.globalTuning.accelerationModifier == .none)
                MouseModifierPicker(title: L10n.string(.MouseSettings.tuningTemporarilyDisableSmoothing), selection: editing.tuningModifierBinding(.disableSmoothScroll))
                    .disabled(!model.settings.globalTuning.smoothEnabled)
                MouseSliderRow(title: L10n.string(.MouseSettings.scrollWheelStep), value: editing.tuningDoubleBinding(\.stepLength), range: 16...120, suffix: "px")
                    .help(L10n.string(.MouseSettings.scrollBaseDistanceStandardNotchedWheel))
                if let notice = editing.modifierAssignmentNotice { MouseEditorFeedback(text: notice) }
            }
        }
    }
}

/// 多个滚动控件共享即时反馈；配置只保留在 SettingsModel，避免第二份草稿。
@MainActor
struct MouseScrollEditing {
    let model: SettingsEditor<MouseEnhancementSettings>
    @Binding var modifierAssignmentNotice: String?

    func resetScrollTuning() {
        model.update(actionName: L10n.string(.MouseSettings.scrollRestoreScrollingFeel)) {
            $0.globalTuning = .defaults
        }
        modifierAssignmentNotice = nil
    }

    func tuningBoolBinding(
        _ keyPath: WritableKeyPath<MouseScrollTuning, Bool>,
        actionName: String
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings.globalTuning[keyPath: keyPath] },
            set: { value in
                model.update(actionName: actionName) {
                    $0.globalTuning[keyPath: keyPath] = value
                }
            }
        )
    }

    func tuningDoubleBinding(_ keyPath: WritableKeyPath<MouseScrollTuning, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings.globalTuning[keyPath: keyPath] },
            set: { value in
                model.update(
                    actionName: L10n.string(.MouseSettings.scrollAdjustScrollingFeel),
                    coalescingKey: "mouse-global-\(String(describing: keyPath))"
                ) { $0.globalTuning[keyPath: keyPath] = value }
            }
        )
    }

    func tuningIntBinding(_ keyPath: WritableKeyPath<MouseScrollTuning, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.globalTuning[keyPath: keyPath]) },
            set: { value in
                model.update(
                    actionName: L10n.string(.MouseSettings.scrollAdjustScrollingFeel),
                    coalescingKey: "mouse-global-\(String(describing: keyPath))"
                ) { $0.globalTuning[keyPath: keyPath] = Int(value.rounded()) }
            }
        )
    }

    func tuningModifierBinding(_ role: MouseScrollModifierRole) -> Binding<MouseModifierGesture> {
        Binding(
            get: { model.settings.globalTuning.modifier(for: role) },
            set: { value in
                var tuning = model.settings.globalTuning
                let clearedRoles = tuning.assignModifier(value, to: role)
                model.update(actionName: L10n.string(.MouseSettings.scrollSetModifier(String(describing: role.displayName)))) {
                    $0.globalTuning = tuning
                }
                modifierAssignmentNotice = MouseEditorFeedback.modifierReassignmentNotice(
                    modifier: value,
                    role: role,
                    clearedRoles: clearedRoles
                )
            }
        )
    }
}
