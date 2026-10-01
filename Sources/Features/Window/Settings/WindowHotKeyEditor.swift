import ArcKitPlatform
import ArcKitWindow
@preconcurrency import AppKit
import SwiftUI

struct WindowHotKeyEditor: View {
    @ObservedObject var model: SettingsEditor<WindowManagementSettings>
    @ObservedObject var hotKeyService: GlobalHotKeyService
    let health: FeatureHealth
    @State private var showsHotKeyResetConfirmation = false


    var body: some View {
        Section(L10n.string(.WindowSettings.pageShortcuts)) {
            HStack {
                Toggle(L10n.string(.WindowSettings.shortcutsEnableShortcuts), isOn: settingBoolBinding(\.hotKeysEnabled, actionName: L10n.string(.WindowSettings.shortcutsToggleShortcuts))
                )
                .help(L10n.string(.WindowSettings.shortcutsMenuBarActionsSnappingRemain))
                Spacer(minLength: 12)
                ArcToolbarButton(title: L10n.string(.Common.restoreDefaults), symbol: .arcRefresh) {
                    showsHotKeyResetConfirmation = true
                }
                .disabled(model.settings.bindings == WindowHotKeyBinding.magnetDefaults)
            }
            LabeledContent(L10n.string(.WindowSettings.shortcutsRegistrationStatus), value: hotKeyStatusText)
            if let warning = hotKeyService.lastRuntimeWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(ArcPalette.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !hotKeyService.unsafeBindings.isEmpty {
                hotKeyWarningBox(title: L10n.string(.WindowSettings.shortcutsShortcutsNeedPrimaryModifier), bindings: hotKeyService.unsafeBindings)
            }
            if !hotKeyService.duplicateBindings.isEmpty {
                hotKeyWarningBox(title: L10n.string(.WindowSettings.shortcutsDuplicateShortcuts), bindings: hotKeyService.duplicateBindings)
            }
            if !hotKeyService.failedBindings.isEmpty {
                hotKeyWarningBox(title: L10n.string(.WindowSettings.shortcutsUnregisteredShortcuts), bindings: hotKeyService.failedBindings)
            }
            ForEach(WindowLayoutAction.allCases) { action in
                hotKeyRow(action)
            }
            .disabled(!model.settings.hotKeysEnabled)
            if !model.settings.hotKeysEnabled {
                Text(L10n.string(.WindowSettings.shortcutsEnableShortcutsEnablingRecording))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .confirmationDialog(
            L10n.string(.WindowSettings.shortcutsRestoreDefaultWindowShortcuts),
            isPresented: $showsHotKeyResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string(.WindowSettings.shortcutsRestoreDefaultShortcuts), role: .destructive) {
                model.update(actionName: L10n.string(.WindowSettings.shortcutsRestoreWindowShortcuts)) {
                    $0.bindings = WindowHotKeyBinding.magnetDefaults
                }
            }
            Button(L10n.string(.Common.cancel), role: .cancel) {}
        } message: {
            Text(L10n.string(.WindowSettings.shortcutsRestoreHint))
        }
    }

    private var hotKeyStatusText: String {
        guard model.settings.isEnabled, model.settings.hotKeysEnabled else {
            return L10n.string(.Common.off)
        }
        guard health.state == .ready || health.state == .partial else { return health.title }
        if hotKeyService.handlerInstallationFailed {
            return L10n.string(.WindowSettings.shortcutsHandlerFailed)
        }
        if hotKeyService.lastRuntimeWarning != nil {
            return L10n.string(.WindowSettings.shortcutsRuntimeError)
        }
        if !hasHotKeyIssues {
            return L10n.string(.WindowSettings.shortcutsRegisteredCount(Int(hotKeyService.registeredCount)))
        }
        return L10n.string(.WindowSettings.shortcutsRegisteredFailed(String(describing: hotKeyService.registeredCount), String(describing: hotKeyIssueCount)))
    }

    private var hasHotKeyIssues: Bool {
        hotKeyIssueCount > 0
    }

    private var hotKeyIssueCount: Int {
        hotKeyService.failedBindings.count
            + hotKeyService.duplicateBindings.count
            + hotKeyService.unsafeBindings.count
            + (hotKeyService.lastRuntimeWarning == nil ? 0 : 1)
    }

    private func hotKeyWarningBox(title: String, bindings: [WindowHotKeyBinding]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(ArcPalette.orange)
            Text(bindings.map { "\($0.action.displayName) \($0.displayShortcut)" }.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(ArcPalette.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(ArcPalette.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ArcPalette.orange.opacity(0.2), lineWidth: 0.5))
    }

    private func settingBoolBinding(
        _ keyPath: WritableKeyPath<WindowManagementSettings, Bool>,
        actionName: String
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                model.update(actionName: actionName) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private func hotKeyRow(_ action: WindowLayoutAction) -> some View {
        let binding = model.settings.binding(for: action)
        let issue = hotKeyIssueText(for: action)
        return HStack(spacing: 8) {
            Toggle(action.displayName, isOn: Binding(
                get: { binding?.isEnabled ?? false },
                set: { value in updateBinding(action) { $0.isEnabled = value } }
            ))
            .toggleStyle(.checkbox)
            .disabled(binding == nil)
            .accessibilityLabel(L10n.string(.WindowSettings.shortcutsEnableShortcut(String(describing: action.displayName))))
            Spacer(minLength: 8)
            if !issue.isEmpty {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(ArcPalette.orange)
            }
            WindowHotKeyRecorder(
                binding: currentBinding(for: action),
                duplicateShortcuts: duplicateShortcuts(for: action)
            )
            .frame(width: 160, height: 28)
        }
        .frame(minHeight: 32)
    }

    private var duplicateActions: Set<WindowLayoutAction> {
        model.settings.duplicateEnabledActions()
    }

    private func duplicateShortcuts(for action: WindowLayoutAction) -> Set<String> {
        guard duplicateActions.contains(action),
              let binding = model.settings.binding(for: action)
        else {
            return []
        }
        return [binding.shortcutIdentifier]
    }

    private func currentBinding(for action: WindowLayoutAction) -> Binding<WindowHotKeyBinding> {
        Binding(
            get: {
                model.settings.binding(for: action)
                    ?? WindowHotKeyBinding(action: action, keyCode: 0, keyEquivalent: "—", modifiers: [], isEnabled: false)
            },
            set: { value in
                updateBinding(action) { $0 = value }
            }
        )
    }

    private func hotKeyIssueText(for action: WindowLayoutAction) -> String {
        guard let binding = model.settings.binding(for: action) else {
            return ""
        }
        guard binding.isEnabled else {
            return ""
        }
        if duplicateActions.contains(action) {
            return L10n.string(.WindowSettings.shortcutsDuplicate)
        }
        if hotKeyService.unsafeBindings.contains(where: { $0.action == action }) {
            return L10n.string(.WindowSettings.shortcutsPrimaryModifierMissing)
        }
        if hotKeyService.failedBindings.contains(where: { $0.action == action }) {
            return hotKeyService.handlerInstallationFailed ? L10n.string(.WindowSettings.shortcutsUnregistered) : L10n.string(.WindowSettings.shortcutsReservedSystem)
        }
        return ""
    }

    private func updateBinding(_ action: WindowLayoutAction, _ transform: @escaping (inout WindowHotKeyBinding) -> Void) {
        let existing = model.settings.binding(for: action)
        var binding = existing
            ?? WindowHotKeyBinding(action: action, keyCode: 0, keyEquivalent: "—", modifiers: [], isEnabled: false)
        transform(&binding)
        // 未录制时按删除键只结束录制，不把临时占位值写入设置。
        guard existing != nil || binding.isSafeGlobalShortcut else { return }
        model.update(actionName: L10n.string(.WindowSettings.shortcutsChangeWindowShortcut)) { settings in
            settings.setBinding(binding)
        }
    }
}
