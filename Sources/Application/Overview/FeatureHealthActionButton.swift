import ArcKitPlatform
import SwiftUI

extension FeatureHealth {
    var color: Color {
        switch state {
        case .ready: ArcPalette.green
        case .blocked, .partial: ArcPalette.orange
        default: ArcPalette.secondaryText
        }
    }
}

/// 运行状态与处理入口由首页展示，不作为普通编辑操作的弹出通知。
struct FeatureHealthActionButton: View {
    let health: FeatureHealth
    let actions: RuntimeHealthActions
    let refresh: () -> Void
    var openSettings: () -> Void = {}
    @State private var confirmsRepair = false

    var body: some View {
        if let action = health.action {
            Button(action.title) {
                switch action {
                case .refresh: refresh()
                case .accessibility:
                    actions.requestAccessibilityPermission()
                case .accessibilitySettings: actions.openAccessibilitySettings()
                case .inputMonitoring: actions.requestMenuInputPermission()
                case .inputMonitoringSettings: actions.openInputMonitoringSettings()
                case .automationSettings: actions.openAutomationSettings()
                case .extensionSettings: actions.openExtensionSettings()
                case .loginItems: actions.openLoginItemsSettings()
                case .repairFinder: confirmsRepair = true
                case .settings: openSettings()
                }
            }
            .buttonStyle(.borderless)
            .confirmationDialog(L10n.string(.Overview.actionRepairFinderExtensionRegistration), isPresented: $confirmsRepair, titleVisibility: .visible) {
                Button(L10n.string(.Overview.actionRepairRestartFinder)) { actions.repairFinderExtension(refresh) }
                Button(L10n.string(.Common.cancel), role: .cancel) {}
            } message: {
                Text(L10n.string(.Overview.actionReRegistersArcKitExtension))
            }
        }
    }
}
