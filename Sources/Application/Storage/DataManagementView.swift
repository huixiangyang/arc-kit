import AppKit
import ArcKitPlatform
import SwiftUI

/// 备份、空间和维护共用一页；状态属于服务，离开页面不会丢失执行结果。
struct DataManagementView: View {
    @ObservedObject var model: DataManagementModel
    @ObservedObject var settingsModel: SettingsModel
    @ObservedObject var supportDiagnosticsService: SupportDiagnosticsService
    @ObservedObject var uninstallService: ArcKitUninstallService
    let actions: DataManagementActions
    @State private var backupScope: DataBackupScope = .allData
    @State private var usage: [StorageUsage] = []
    @State private var usageError: String?
    @State private var isRefreshingUsage = false
    @State private var showsResetConfirmation = false
    @State private var showsRestoreConfirmation = false
    @State private var showsUninstallConfirmation = false

    var body: some View {
        Group {
            Section {
                HStack {
                    Picker(L10n.string(.DataManagement.dataBackupContents), selection: $backupScope) {
                        ForEach(DataBackupScope.allCases) { Text($0.title).tag($0) }
                    }
                    .help(L10n.string(.DataManagement.dataAllDataIncludesSettingsTemplatesWallpapers))
                    Spacer()
                    Button(L10n.string(.DataManagement.dataExportBackup)) { actions.exportBackup(backupScope) }
                    Button(L10n.string(.DataManagement.dataRestoreBackup), action: actions.restoreBackup)
                }
                .disabled(isWorking)
                HStack {
                    Text(L10n.string(.DataManagement.dataLatestSettingsRestorePoint))
                    Spacer()
                    Text(automaticBackupTitle).foregroundStyle(.secondary)
                    Button(L10n.string(.DataManagement.dataRestore)) { showsRestoreConfirmation = true }
                        .disabled(model.lastAutomaticBackup == nil || model.isLoadingAutomaticBackupMetadata || isWorking)
                }
                .help(L10n.string(.DataManagement.dataCreatedAutomaticallyImportingSettingsRestoring))
                if let error = model.automaticBackupMetadataError {
                    feedback(error, isError: true, actionTitle: L10n.string(.DataManagement.dataCheckAgain), action: model.refreshAutomaticBackupMetadata)
                }
            } header: {
                Text(L10n.string(.DataManagement.dataBackupRestore))
            } footer: {
                transferFeedback
            }
            Section(L10n.string(.DataManagement.dataStorage)) {
                HStack {
                    Text(L10n.string(.DataManagement.dataDataFolder))
                    Spacer()
                    Text(model.database.paths.root.path)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(model.database.paths.root.path)
                    Button(L10n.string(.Common.`open`)) { NSWorkspace.shared.open(model.database.paths.root) }
                    ArcIconActionButton(title: L10n.string(.DataManagement.dataRefreshStorageUsage), symbol: .refreshCw) { Task { await refreshUsage() } }
                        .disabled(isRefreshingUsage || isWorking)
                }
                ForEach(usage) { item in
                    HStack {
                        Text(item.kind.title)
                        Spacer()
                        Text(L10n.fileSize(item.bytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                        if item.kind == .cache {
                            Button(L10n.string(.DataManagement.dataClear)) { Task { try? await model.performStorageOperation(.clearCache) } }
                                .disabled(isWorking)
                                .help(L10n.string(.DataManagement.dataClearsRebuildableCachesAssetsConfiguration))
                        }
                    }
                }
                if let usageError { feedback(usageError, isError: true) }
            }
            Section(L10n.string(.DataManagement.storageDiagnostics)) {
                HStack {
                    Text(L10n.string(.DataManagement.dataDiagnosticReport))
                    Spacer()
                    Button(diagnosticsWorking ? L10n.string(.DataManagement.dataExporting) : L10n.string(.DataManagement.dataExportDiagnostics), action: actions.exportSupportDiagnostics)
                        .disabled(isWorking)
                }
                .help(L10n.string(.DataManagement.dataSavesStatusSummaryRecentRedacted))
                diagnosticsFeedback
            }
            Section(L10n.string(.DataManagement.dataResetUninstall)) {
                HStack {
                    Text(L10n.string(.Settings.saveRestoreDefaultSettings))
                    Spacer()
                    Button(L10n.string(.DataManagement.dataRestoreDefaults), role: .destructive) { showsResetConfirmation = true }
                        .disabled(isWorking || settingsModel.isUsingDefaultSettings)
                }
                HStack {
                    Text(L10n.string(.DataManagement.dataUninstallArcKit))
                    Spacer()
                    Button(L10n.string(.DataManagement.dataUninstall), role: .destructive) { showsUninstallConfirmation = true }
                        .disabled(isWorking)
                }
                switch uninstallService.state {
                case .idle: EmptyView()
                case let .working(message): feedback(message)
                case let .failed(message):
                    feedback(message, isError: true, actionTitle: L10n.string(.Common.close), action: uninstallService.clearFailure)
                }
            }
        }
        .task {
            model.refreshAutomaticBackupMetadata()
            await refreshUsage()
        }
        .onChange(of: model.transferState) { state in
            if case .succeeded = state { Task { await refreshUsage() } }
        }
        .confirmationDialog(L10n.string(.DataManagement.dataRestoreDefaultSettings), isPresented: $showsResetConfirmation, titleVisibility: .visible) {
            Button(L10n.string(.DataManagement.dataBackUpRestoreDefaults), role: .destructive) { Task { await model.resetWithAutomaticBackup() } }
        } message: {
            Text(L10n.string(.DataManagement.dataResetsGeneralFinderWindowMouseSettings))
        }
        .confirmationDialog(L10n.string(.DataManagement.dataRestoreLatestSettingsRestorePoint), isPresented: $showsRestoreConfirmation, titleVisibility: .visible) {
            Button(L10n.string(.DataManagement.dataBackUpCurrentSettingsRestore), role: .destructive) { Task { await model.restoreAutomaticBackup() } }
        } message: {
            Text(L10n.string(.DataManagement.dataCurrentSettingsBecomeNewRestorePoint))
        }
        .confirmationDialog(L10n.string(.DataManagement.dataUninstallConfirmation), isPresented: $showsUninstallConfirmation, titleVisibility: .visible) {
            Button(L10n.string(.DataManagement.dataUninstallKeepData), role: .destructive) { actions.uninstallArcKit(false) }
            Button(L10n.string(.DataManagement.dataUninstallRemoveData), role: .destructive) { actions.uninstallArcKit(true) }
        } message: {
            Text(L10n.string(.DataManagement.dataUnregistersLoginItemsBackgroundServices))
        }
    }

    private var isWorking: Bool { model.isOperationRunning || diagnosticsWorking || uninstallService.isWorking }
    private var diagnosticsWorking: Bool {
        if case .working = supportDiagnosticsService.exportState { return true }
        return false
    }
    private var automaticBackupTitle: String {
        if model.isLoadingAutomaticBackupMetadata { return L10n.string(.DataManagement.dataChecking) }
        if model.automaticBackupMetadataError != nil { return L10n.string(.App.menuBarCheckFailed) }
        guard let backup = model.lastAutomaticBackup else { return L10n.string(.DataManagement.dataRestorePointYetMissing) }
        return SettingsBackupPresentation.localizedDateTime(backup.createdAt)
    }

    @ViewBuilder private var transferFeedback: some View {
        switch model.transferState {
        case .idle: EmptyView()
        case let .working(message): feedback(message)
        case let .succeeded(message):
            feedback(message, actionTitle: model.lastExportedBackupURL == nil ? L10n.string(.Common.close) : L10n.string(.DataManagement.dataShowFinder),
                     action: model.lastExportedBackupURL == nil ? model.clearTransferState : actions.revealExportedBackup)
        case let .failed(message):
            feedback(message, isError: true, actionTitle: L10n.string(.Common.close), action: model.clearTransferState)
        }
    }

    @ViewBuilder private var diagnosticsFeedback: some View {
        switch supportDiagnosticsService.exportState {
        case .idle, .working: EmptyView()
        case let .succeeded(fileName):
            feedback(L10n.string(.DataManagement.dataExported(String(describing: fileName))), actionTitle: L10n.string(.DataManagement.dataShowFinder), action: supportDiagnosticsService.revealExportedReport)
        case let .failed(message):
            feedback(message, isError: true, actionTitle: L10n.string(.Common.close), action: supportDiagnosticsService.clearFeedback)
        }
    }

    private func feedback(_ message: String, isError: Bool = false, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(message).font(.caption).foregroundStyle(isError ? ArcPalette.red : .secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.link) }
        }
    }

    private func refreshUsage() async {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        let service = StorageMaintenance(database: model.database)
        do {
            usage = try await Task.detached { try service.usage() }.value
            usageError = nil
        } catch { usageError = error.localizedDescription }
    }
}
