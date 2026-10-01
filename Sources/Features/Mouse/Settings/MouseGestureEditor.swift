import ArcKitPlatform
import ArcKitMouse
@preconcurrency import AppKit
import SwiftUI

struct MouseGestureEditor: View {
    @ObservedObject var model: SettingsEditor<MouseEnhancementSettings>
    @ObservedObject var mouseService: MouseScrollEnhancementService
    @State private var showsGestureResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    ArcToolbarButton(title: L10n.string(.MouseSettings.gesturesRestoreRecommendedGestures), symbol: .arcRefresh) {
                        showsGestureResetConfirmation = true
                    }
                    .disabled(model.settings.gestureSettings == .defaults)
                }
                Toggle(L10n.string(.MouseSettings.gesturesEnableMouseGestures), isOn: gestureBoolBinding(\.isEnabled, actionName: L10n.string(.MouseSettings.gesturesToggleMouseGestures))
                )
                    .help(L10n.string(.MouseSettings.gesturesNormalRightClickTriggersRelease))
                gestureTriggerPicker()
                MouseSliderRow(
                    title: L10n.string(.MouseSettings.gesturesTriggerDistance),
                    value: gestureDistanceBinding(),
                    range: 40...180,
                    suffix: "px"
                )
                Toggle(L10n.string(.MouseSettings.gesturesShowGestureHints), isOn: gestureBoolBinding(\.showVisualHint, actionName: L10n.string(.MouseSettings.gesturesToggleGestureHints))
                )
                    .help(L10n.string(.MouseSettings.gesturesShowsDirectionDistancePendingAction))
                ForEach(MouseGestureDirection.allCases, id: \.self) { direction in
                    gestureActionPicker(direction: direction)
                }

            }
        }
        .confirmationDialog(
            L10n.string(.MouseSettings.gesturesRestoreConfirmation),
            isPresented: $showsGestureResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string(.MouseSettings.gesturesRestoreRecommendedMouseGestures), role: .destructive, action: resetGestureSettings)
            Button(L10n.string(.Common.cancel), role: .cancel) {}
        } message: {
            Text(L10n.string(.MouseSettings.gesturesRestoresGestureEnablementDistanceHintsAll))
        }
    }

    private func resetGestureSettings() {
        model.update(actionName: L10n.string(.MouseSettings.gesturesRestoreRecommendedGestures)) {
            $0.gestureSettings = .defaults
        }
    }

    private func gestureBoolBinding(
        _ keyPath: WritableKeyPath<MouseGestureSettings, Bool>,
        actionName: String
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings.gestureSettings[keyPath: keyPath] },
            set: { value in
                model.update(actionName: actionName) {
                    $0.gestureSettings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func gestureDistanceBinding() -> Binding<Double> {
        Binding(
            get: { model.settings.gestureSettings.minimumDistance },
            set: { value in
                model.update(actionName: L10n.string(.MouseSettings.gesturesAdjustGestureDistance), coalescingKey: "mouse-gesture-distance") {
                    $0.gestureSettings.minimumDistance = value.rounded()
                }
            }
        )
    }

    private func gestureTriggerBinding() -> Binding<MouseGestureTriggerButton> {
        Binding(
            get: { model.settings.gestureSettings.triggerButton },
            set: { value in
                model.update(actionName: L10n.string(.MouseSettings.gesturesChangeGestureTrigger)) {
                    $0.gestureSettings.triggerButton = value
                }
            }
        )
    }

    private func gestureActionBinding(direction: MouseGestureDirection) -> Binding<MouseGestureAction> {
        Binding(
            get: {
                model.settings.gestureSettings.bindings.first { $0.direction == direction }?.action ?? .none
            },
            set: { action in
                model.update(actionName: L10n.string(.MouseSettings.gesturesSetGestureAction(String(describing: direction.displayName)))) { settings in
                    if let index = settings.gestureSettings.bindings.firstIndex(where: { $0.direction == direction }) {
                        settings.gestureSettings.bindings[index].action = action
                    } else {
                        mouseService.reportConfigurationFailure(L10n.string(.MouseSettings.gesturesMouseGestureSettingsMissingReloadSettings))
                    }
                }
            }
        )
    }

    private func gestureTriggerPicker() -> some View {
        HStack(spacing: 10) {
            Text(L10n.string(.MouseSettings.gesturesTrigger))
                .font(.subheadline)
                .foregroundStyle(ArcPalette.primaryText)
                .frame(width: 76, alignment: .leading)
            Picker("", selection: gestureTriggerBinding()) {
                ForEach(MouseGestureTriggerButton.allCases, id: \.self) { trigger in
                    Text(trigger.displayName).tag(trigger)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
        .padding(8)
        .background(ArcPalette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func gestureActionPicker(direction: MouseGestureDirection) -> some View {
        HStack(spacing: 10) {
            Text(direction.displayName)
                .font(.subheadline)
                .foregroundStyle(ArcPalette.primaryText)
                .frame(width: 76, alignment: .leading)
            Picker("", selection: gestureActionBinding(direction: direction)) {
                ForEach(MouseGestureAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Spacer()
        }
        .padding(8)
        .background(ArcPalette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
