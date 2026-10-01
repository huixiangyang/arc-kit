import ArcKitPlatform
import SwiftUI

/// 诊断展示具体检测证据；后台按需休眠不属于故障，回执也不代表文件动作已验证。
struct FinderDiagnosticsView: View {
    @ObservedObject var healthModel: AppRuntimeHealthModel
    let health: FeatureHealth
    let actions: RuntimeHealthActions
    let refresh: () -> Void

    var body: some View {
        Section(L10n.string(.FinderSettings.diagnosticsFinderDiagnostics)) {
            if let result = healthModel.finderHealth, !healthModel.isPreview {
                LabeledContent(L10n.string(.FinderSettings.diagnosticsChecked), value: result.checkedAtDescription)
                LabeledContent(L10n.string(.FinderSettings.diagnosticsComponentFiles), value: result.extensionFileExists && result.agentFileExists ? L10n.string(.FinderSettings.diagnosticsPresent) : L10n.string(.FinderSettings.diagnosticsMissing))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsExtensionRegistration), value: result.plugInKitOnlyCurrentPath ? L10n.string(.FinderSettings.diagnosticsCurrentInstallationPath) : L10n.string(.FinderSettings.diagnosticsIssueDetected))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsExtensionPermission), value: result.extensionEnabledByUser ? L10n.string(.Runtime.permissions) : L10n.string(.Runtime.permissionsOff))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsLiveResponse), value: result.extensionRuntimeResponded ? L10n.string(.FinderSettings.diagnosticsReceived) : L10n.string(.FinderSettings.extensionNotReceived))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsBackgroundRegistration), value: result.launchAgentLoaded ? L10n.string(.FinderSettings.diagnosticsAllowedRun) : result.launchAgentRequiresApproval ? L10n.string(.FinderSettings.diagnosticsAwaitingBackgroundPermission) : L10n.string(.FinderSettings.diagnosticsNotReady))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsBackgroundProcess), value: !result.agentRunning ? L10n.string(.FinderSettings.diagnosticsOnDemandHint) : result.agentOnlyCurrentProcess ? L10n.string(.FinderSettings.diagnosticsCurrentInstallation) : L10n.string(.FinderSettings.diagnosticsInstancePathIssue))
                LabeledContent(L10n.string(.FinderSettings.diagnosticsMenuConfiguration), value: result.snapshotExists ? L10n.string(.FinderSettings.diagnosticsGenerated) : L10n.string(.FinderSettings.diagnosticsNotGenerated))
                HStack {
                    FeatureHealthActionButton(health: health, actions: actions, refresh: refresh)
                    Spacer()
                    Button(L10n.string(.FinderSettings.diagnosticsTechnicalDetails), action: actions.showFinderExtensionDiagnostics)
                }
            } else {
                Text(healthModel.isPreview ? L10n.string(.FinderSettings.diagnosticsDebugScope) : L10n.string(.FinderSettings.diagnosticsResultsYetMissing))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
