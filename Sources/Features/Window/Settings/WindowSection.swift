import ArcKitPlatform
import ArcKitWindow
@preconcurrency import AppKit
import SwiftUI

enum WindowWorkspaceTab: String, CaseIterable, Identifiable {
    case snapping, scenes, hotKeys, rules
    var id: Self { self }
    var title: String {
        switch self {
        case .snapping: L10n.string(.WindowSettings.pageSnapping)
        case .scenes: L10n.string(.WindowSettings.scenesTitle)
        case .hotKeys: L10n.string(.WindowSettings.pageShortcuts)
        case .rules: L10n.string(.WindowSettings.pageAppsDisplays)
        }
    }
}

struct WindowSection: View {
    @ObservedObject var model: SettingsEditor<WindowManagementSettings>
    @ObservedObject var windowService: WindowManagementService
    @ObservedObject var hotKeyService: GlobalHotKeyService
    let health: FeatureHealth
    @Binding var selectedTab: WindowWorkspaceTab


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                featureControl
                Picker(L10n.string(.WindowSettings.pageWindowSettings), selection: $selectedTab) {
                    ForEach(WindowWorkspaceTab.allCases) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Form {
                // 上次操作结果独立于配置提交后的短暂等待回包，不能随健康状态反复显隐。
                if let result = windowService.lastResult, !result.succeeded {
                    inlineWarning(title: L10n.string(.WindowSettings.pageActionIncomplete), detail: result.userMessage ?? L10n.string(.WindowSettings.pageRetryRegularWindow))
                }
                switch selectedTab {
                case .snapping:
                    Section(L10n.string(.WindowSettings.pageSnapping)) {
                        Toggle(L10n.string(.WindowSettings.pageDragScreenEdgesResizeWindows), isOn: settingBoolBinding(\.dragSnapEnabled, actionName: L10n.string(.WindowSettings.pageToggleSnapping)))
                        if model.settings.dragSnapEnabled {
                            Toggle(L10n.string(.WindowSettings.pageShowTargetPositionPreview), isOn: settingBoolBinding(\.showSnapPreview, actionName: L10n.string(.WindowSettings.pageToggleSnappingPreview)))
                        }
                        HStack {
                            Text(L10n.string(.WindowSettings.pageWindowSpacing))
                            Slider(value: Binding(
                                get: { model.settings.windowGap },
                                set: { value in model.update(actionName: L10n.string(.WindowSettings.pageAdjustWindowSpacing), coalescingKey: "window-gap") { $0.windowGap = value } }
                            ), in: 0...64, step: 2)
                            Text("\(Int(model.settings.windowGap)) px").monospacedDigit()
                        }
                    }
                case .hotKeys:
                    WindowHotKeyEditor(model: model, hotKeyService: hotKeyService, health: health)
                case .scenes:
                    WindowScenesEditor(model: model, windowService: windowService)
                case .rules:
                    WindowRulesEditor(model: model, windowService: windowService)
                }
            }
            .formStyle(.grouped)
            .appBackgroundSurface()
            .id(selectedTab)
        }
    }

    private var featureControl: some View {
        Toggle(model.settings.isEnabled ? L10n.string(.Common.enabled) : L10n.string(.Common.disabled),
               isOn: settingBoolBinding(\.isEnabled, actionName: L10n.string(.App.applicationToggleWindowManagement)))
            .toggleStyle(.switch)
            .fixedSize()
            .accessibilityLabel(L10n.string(.WindowSettings.pageEnableWindowManagement))
            .help(L10n.string(.WindowSettings.pageWindowManagement(String(describing: health.title))))
    }

    private func inlineWarning(
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            ArcIcon(.triangleAlert, size: 18)
                .foregroundStyle(ArcPalette.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(ArcPalette.secondaryText)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(ArcPalette.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
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
}
