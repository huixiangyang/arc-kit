import ArcKitFinder
import ArcKitPlatform
import Foundation

/// 技术报告在后台采集，正文只作为可滚动文本展示，不参与窗口尺寸计算。
enum FinderDiagnosticsReport {
    static func capture(
        snapshotStore: FinderExtensionSnapshotStore,
        health: FinderExtensionStatusService.HealthStatus,
        accessibilityStatus: String
    ) -> String {
        // 只读取已发布快照，不重建或广播默认配置。
        let snapshot = snapshotStore.load()
        let latestLog = ShellExecutor.runWithOutput(
            "tail -n 30 \(ShellQuoting.shellQuoted(ArcKitStoragePaths.current.logs.appendingPathComponent("host.jsonl").path)) 2>/dev/null",
            timeout: 5
        ) ?? L10n.string(.FinderSettings.reportLogsYetMissing)
        let snapshotPath = L10n.string(.FinderSettings.reportSecureMachServiceGroupContainersFileMissing)
        return L10n.string(.FinderSettings.reportConnectionChecklist(String(describing: snapshot.map { String($0.schemaVersion) } ?? L10n.string(.FinderSettings.extensionNotReceived)), String(describing: snapshot.map { String($0.observedDirectoryPaths.count) } ?? L10n.string(.FinderSettings.extensionNotReceived)), String(describing: snapshotPath), String(describing: ArcKitConstants.installedRuntimeHostPath), String(describing: health.criticalChecksPassed ? L10n.string(.FinderSettings.extensionPassed) : L10n.string(.FinderSettings.diagnosticsIssueDetected)), String(describing: health.checkedAtDescription), String(describing: health.snapshotExists ? health.snapshotAgeDescription : L10n.string(.FinderSettings.reportBroadcastReceivedMissing)), String(describing: health.extensionFileExists ? L10n.string(.FinderSettings.diagnosticsPresent) : L10n.string(.FinderSettings.diagnosticsMissing)), String(describing: health.extensionEnabledByUser ? L10n.string(.FinderSettings.reportFinderAccessAllowed) : L10n.string(.WindowSettings.recorderDisabled)), String(describing: health.extensionRuntimeResponded ? health.extensionRuntimeAgeDescription : L10n.string(.FinderSettings.reportResponseTimeMissing)), String(describing: health.plugInKitRegistered ? L10n.string(.FinderSettings.reportRegistered) : L10n.string(.WindowSettings.shortcutsUnregistered)), String(describing: health.plugInKitPathVerified ? L10n.string(.FinderSettings.reportPointsInstallation) : L10n.string(.FinderSettings.reportInstallationMismatch)), String(describing: health.plugInKitOnlyCurrentPath ? L10n.string(.FinderSettings.reportExclusiveInstallation) : L10n.string(.FinderSettings.reportOldPathsDuplicateRegistrationsFound)), String(describing: health.agentFileExists ? L10n.string(.FinderSettings.diagnosticsPresent) : L10n.string(.FinderSettings.diagnosticsMissing)), String(describing: health.agentRunning ? L10n.string(.FinderSettings.reportRunning) : L10n.string(.FinderSettings.reportNotRunning)), String(describing: health.agentProcessPathVerified ? L10n.string(.FinderSettings.reportCurrentInstallation) : L10n.string(.FinderSettings.reportAnotherInstallation)), String(describing: health.agentOnlyCurrentProcess ? L10n.string(.FinderSettings.reportOneCurrentProcess) : L10n.string(.FinderSettings.reportOldDuplicateProcessesFound)), String(describing: health.launchAgentPlistExists ? L10n.string(.FinderSettings.diagnosticsPresent) : L10n.string(.FinderSettings.diagnosticsMissing)), String(describing: health.launchAgentLoaded ? L10n.string(.Runtime.permissionsAllowed) : health.launchAgentDescription), String(describing: accessibilityStatus), String(describing: health.commandChannelDescription), String(describing: health.plugInKitSummary), String(describing: health.launchAgentDescription), String(describing: health.agentProcessSummary), String(describing: latestLog)))
    }
}
