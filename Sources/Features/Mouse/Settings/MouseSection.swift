import ArcKitPlatform
import ArcKitMouse
@preconcurrency import AppKit
import SwiftUI

enum MouseWorkspaceTab: String, CaseIterable, Identifiable {
    case scrolling, applications, gestures, advanced
    var id: Self { self }
    var title: String {
        switch self {
        case .scrolling: L10n.string(.MouseSettings.scrollScrolling)
        case .applications: L10n.string(.MouseSettings.pageAppRules)
        case .gestures: L10n.string(.MouseSettings.pageRightClickGestures)
        case .advanced: L10n.string(.MouseSettings.pageAdvanced)
        }
    }
}

struct MouseSection: View {
    @ObservedObject var model: SettingsEditor<MouseEnhancementSettings>
    @ObservedObject var mouseService: MouseScrollEnhancementService
    let applicationCandidate: () -> MouseApplicationCandidate?
    let health: FeatureHealth
    @Binding var selectedTab: MouseWorkspaceTab
    @State private var modifierAssignmentNotice: String?


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                mouseControl
                Picker(L10n.string(.MouseSettings.pageMouseSettings), selection: $selectedTab) {
                    ForEach(MouseWorkspaceTab.allCases) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Form {
                switch selectedTab {
                case .scrolling:
                    MouseScrollingEditor(model: model, editing: scrollEditing)
                case .applications:
                    MouseApplicationsEditor(model: model, mouseService: mouseService, applicationCandidate: applicationCandidate)
                case .gestures:
                    Section(L10n.string(.MouseSettings.pageRightClickGestures)) {
                        MouseGestureEditor(model: model, mouseService: mouseService)
                    }
                case .advanced:
                    MouseAdvancedEditor(model: model, editing: scrollEditing)
                }
            }
            .formStyle(.grouped)
            .appBackgroundSurface()
            .id(selectedTab)
        }
    }

    private var scrollEditing: MouseScrollEditing {
        MouseScrollEditing(
            model: model,
            modifierAssignmentNotice: $modifierAssignmentNotice
        )
    }

    private var mouseControl: some View {
        Toggle(model.settings.isEnabled ? L10n.string(.Common.enabled) : L10n.string(.Common.disabled),
               isOn: binding(\.isEnabled, actionName: L10n.string(.App.applicationToggleMouseEnhancement)))
            .toggleStyle(.switch)
            .fixedSize()
            .accessibilityLabel(L10n.string(.MouseSettings.pageEnableMouseEnhancement))
            .help(L10n.string(.MouseSettings.pageMouseEnhancement(String(describing: health.title))))
    }

    private func binding(
        _ keyPath: WritableKeyPath<MouseEnhancementSettings, Bool>,
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


/// 输入事件计数只用于排障，不作为日常滚动设置的一部分。
struct MouseDiagnosticsView: View {
    @ObservedObject var mouseService: MouseScrollEnhancementService

    var body: some View {
        Section(L10n.string(.MouseSettings.pageScrollDiagnostics)) {
            let diagnostic = mouseService.scrollDiagnostics
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(.MouseSettings.pageWheelInputNativeGesturesPassedThrough(String(describing: diagnostic.wheelInputs), String(describing: diagnostic.nativeGestureInputs), String(describing: diagnostic.bypassedInputs))))
                Text(L10n.string(.MouseSettings.pageValidEventsSmoothFramesFallbacks(String(describing: diagnostic.output.generatedEvents), String(describing: diagnostic.output.postedFrames), String(describing: diagnostic.output.directFallbacks))))
                Text(L10n.string(.MouseSettings.pageTargetPid(String(describing: diagnostic.targetBundleIdentifier ?? L10n.string(.MouseSettings.pageNotDetected)), String(describing: diagnostic.targetProcessID))))
                Text(diagnostic.targetWindowAvailable ? L10n.string(.MouseSettings.pageSystemTargetWindowIdentified) : L10n.string(.MouseSettings.pageSystemTargetWindowIdentifiedYetMissing))
                Text(L10n.string(.MouseSettings.pageDeliveryCountHint))
                    .foregroundStyle(.secondary)
                Button(L10n.string(.MouseSettings.pageRefreshScrollDiagnostics)) { mouseService.refresh() }
                MouseScrollTestArea()
            }
            .font(.caption)
        }
    }
}
