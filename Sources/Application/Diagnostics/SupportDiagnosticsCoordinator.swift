import ArcKitPlatform
import AppKit
import ArcKitFinder
import Foundation
import UniformTypeIdentifiers

/// 诊断导出流程拥有选择位置、刷新运行态和采集报告的顺序，主控制器不拼装诊断数据。
@MainActor
final class SupportDiagnosticsCoordinator {
    private let runtime: ApplicationRuntime
    private let loginService: LaunchAtLoginService
    private let supportDiagnosticsService: SupportDiagnosticsService

    init(
        runtime: ApplicationRuntime,
        loginService: LaunchAtLoginService,
        exportService: SupportDiagnosticsService
    ) {
        self.runtime = runtime
        self.loginService = loginService
        self.supportDiagnosticsService = exportService
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.title = L10n.string(.Diagnostics.exportExportArcKitDiagnosticReport)
        panel.prompt = L10n.string(.Common.export)
        panel.message = SupportDiagnosticPackage.privacyNotice
        panel.nameFieldStringValue = L10n.string(.Diagnostics.exportArcKitDiagnosticsJson(String(describing: SettingsBackupPresentation.fileTimestamp())))
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 导出前立即刷新主进程结构化运行态，避免把旧心跳当成当前状态。
        runtime.recorder.write(reason: "support-diagnostics-export", force: true)
        var warnings: [SupportDiagnosticSource] = []
        let mainRuntime: ArcKitMainAppRuntimeState?
        do {
            mainRuntime = try ArcKitRuntimeStateStore.load()
        } catch {
            mainRuntime = nil
            warnings.append(.mainRuntime)
        }
        let finderRuntime: FinderExtensionRuntimeState?
        do {
            finderRuntime = try FinderExtensionRuntimeStateStore().loadMostRelevant()
        } catch {
            finderRuntime = nil
            warnings.append(.finderExtensionRuntime)
        }
        let finderCommandRuntime: FinderCommandExecutionRuntimeState?
        do {
            finderCommandRuntime = try FinderCommandExecutionRuntimeStateStore().load()
        } catch {
            finderCommandRuntime = nil
            warnings.append(.finderCommandRuntime)
        }

        let report = SupportDiagnosticReportBuilder().build(
            settings: runtime.committedSettings ?? .defaults,
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
            applicationBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
            bundlePath: Bundle.main.bundlePath,
            launchAtLoginStatus: loginService.launchAtLoginState.displayName,
            mainRuntime: mainRuntime,
            finderExtensionRuntime: finderRuntime,
            finderCommandRuntime: finderCommandRuntime,
            collectionWarnings: warnings
        )
        supportDiagnosticsService.export(report, to: url)
    }

}
