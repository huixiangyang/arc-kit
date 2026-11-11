import ArcKitPlatform
import SwiftUI

struct MenuBarPreferencesSheet: View {
    @ObservedObject var model: SettingsEditor<MenuBarSettings>
    @ObservedObject var service: MenuBarManagementService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.string(.MenuBar.flowSettings)).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(L10n.string(.Common.close)) {
                    Task { if await model.commitPendingChanges() { dismiss() } }
                }.keyboardShortcut(.defaultAction)
            }
            autoCollapse
            Divider()
            shortcuts
            if service.partitionMode.supportsSections {
                Divider()
                Toggle(L10n.string(.MenuBar.settingsDeepSection), isOn: binding(\.deepSectionEnabled, actionName: L10n.string(.MenuBar.settingsDeepSection)))
                    .toggleStyle(.switch).controlSize(.small)
                if model.settings.deepSectionEnabled {
                    Text(L10n.string(.MenuBar.flowDeepHint)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.failureMessage { notice(error, icon: .triangleAlert) }
            else if model.hasUncommittedChanges { notice(L10n.string(.MenuBar.settingsPending), icon: .circleInfo) }
        }.padding(24).frame(width: 480)
    }

    private var autoCollapse: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.string(.MenuBar.autoCollapseEnabled), isOn: binding(\.autoCollapseEnabled, actionName: L10n.string(.MenuBar.autoCollapseEdit)))
                .toggleStyle(.switch).controlSize(.small)
            HStack {
                Text(L10n.string(.MenuBar.autoCollapseDelay))
                Spacer()
                Text(L10n.string(.MenuBar.autoCollapseMinutes(String(model.settings.autoCollapseDelayMinutes))))
                    .monospacedDigit()
            }.font(.system(size: 13))
            Slider(value: Binding(get: { Double(model.settings.autoCollapseDelayMinutes) }, set: { value in
                model.update(actionName: L10n.string(.MenuBar.autoCollapseEdit), coalescingKey: "menu-bar.auto-collapse-delay") { $0.autoCollapseDelayMinutes = Int(value) }
            }), in: Double(MenuBarSettings.autoCollapseDelayRange.lowerBound)...Double(MenuBarSettings.autoCollapseDelayRange.upperBound), step: 1) {
                Text(L10n.string(.MenuBar.autoCollapseDelay))
            }.labelsHidden()
                .disabled(!model.settings.autoCollapseEnabled)
                .accessibilityValue(L10n.string(.MenuBar.autoCollapseMinutes(String(model.settings.autoCollapseDelayMinutes))))
            Text(L10n.string(.MenuBar.autoCollapseHint))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(L10n.string(.MenuBar.hotKeyEnable), isOn: binding(\.shortcutsEnabled, actionName: L10n.string(.MenuBar.hotKeyEdit)))
                .toggleStyle(.switch).controlSize(.small)
            ForEach(MenuBarHotKeyAction.allCases, id: \.self) { shortcutRecorder($0) }
            if service.isRecordingShortcut {
                notice(L10n.string(.MenuBar.hotKeyRecording), icon: .command)
            } else if !service.hotKeyFailures.isEmpty {
                ForEach(MenuBarHotKeyAction.allCases, id: \.self) { action in
                    if let code = service.hotKeyFailures[action] {
                        notice(L10n.string(.MenuBar.hotKeyFailure(
                            L10n.string(action.title), String(code))), icon: .triangleAlert)
                    }
                }
                Button(L10n.string(.MenuBar.hotKeyRetry), action: service.retryHotKeys)
            } else if !service.registeredHotKeyActions.isEmpty {
                notice(L10n.string(.MenuBar.hotKeyRegistered), icon: .checkCircle)
            }
        }
    }

    private func shortcutRecorder(_ action: MenuBarHotKeyAction) -> some View {
        let keyPath = action.keyPath
        let duplicates = Set(MenuBarHotKeyAction.allCases.filter { $0 != action }
            .map { model.settings[keyPath: $0.keyPath] }.filter(\.isEnabled).map(\.shortcutIdentifier))
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(action.title)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if action.requiresCollection, !model.settings.isEnabled, model.settings[keyPath: keyPath].isEnabled {
                    Text(L10n.string(.MenuBar.hotKeyCollectionOff)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            KeyboardShortcutRecorder(binding: Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
                model.update(actionName: L10n.string(.MenuBar.hotKeyEdit)) { $0[keyPath: keyPath] = value }
            }), duplicateShortcuts: duplicates, rejectDuplicates: true,
                onRecordingChange: { service.setShortcutRecording(owner: $0, active: $1) })
                .frame(width: 200, height: 30)
                .accessibilityLabel(L10n.string(action.title))
            Button {
                model.update(actionName: L10n.string(.MenuBar.hotKeyEdit)) { $0[keyPath: keyPath].isEnabled = false }
            } label: { ArcIcon(.circleX, size: 14) }
                .buttonStyle(.plain).disabled(!model.settings[keyPath: keyPath].isEnabled)
                .help(L10n.string(.Common.shortcutRecorderDisable))
                .accessibilityLabel(L10n.string(.Common.shortcutRecorderDisable))
        }.frame(minHeight: 32)
    }

    private func binding(_ keyPath: WritableKeyPath<MenuBarSettings, Bool>, actionName: String) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            model.update(actionName: actionName) { $0[keyPath: keyPath] = value }
        })
    }
    private func notice(_ text: String, icon: ArcIconName) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ArcIcon(icon, size: 14).foregroundStyle(ArcPalette.orange)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
