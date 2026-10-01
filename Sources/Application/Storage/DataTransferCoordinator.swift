import ArcKitPlatform
import AppKit
import Foundation
import UniformTypeIdentifiers

public enum DataBackupScope: String, CaseIterable, Identifiable, Sendable {
    case allData, settings
    public var id: Self { self }
    var title: String { self == .allData ? L10n.string(.DataManagement.transferAllData) : L10n.string(.DataManagement.transferSettingsTemplates) }
}

/// 备份只有一组导出/恢复入口；恢复范围由所选文件决定，不依赖导出范围。
@MainActor
final class DataTransferCoordinator {
    private let dataModel: DataManagementModel

    init(dataModel: DataManagementModel) { self.dataModel = dataModel }

    func exportBackup(scope: DataBackupScope) {
        guard !dataModel.isOperationRunning else { return }
        let panel = NSSavePanel()
        panel.title = L10n.string(.DataManagement.transferExport(String(describing: scope.title)))
        panel.prompt = L10n.string(.Common.export)
        let suffix = scope == .allData ? "arckitbackup" : "json"
        panel.nameFieldStringValue = "ArcKit-\(SettingsBackupPresentation.fileTimestamp()).\(suffix)"
        if scope == .settings { panel.allowedContentTypes = [.json] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                switch scope {
                case .allData: try await dataModel.performStorageOperation(.export(url))
                case .settings: _ = try await dataModel.exportBackup(to: url)
                }
            } catch { showFailure(L10n.string(.DataManagement.transferBackupExportFailed), error) }
        }
    }

    func revealExportedBackup() {
        guard let url = dataModel.exportedBackupURLForReveal() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func restoreBackup() {
        guard !dataModel.isOperationRunning else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.string(.DataManagement.transferRestoreArcKitBackup)
        panel.prompt = L10n.string(.DataManagement.transferChooseBackup)
        panel.message = L10n.string(.DataManagement.transferRestorePickerHint)
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if isDirectory, url.pathExtension.lowercased() == "arckitbackup" {
                    guard confirmRestore(
                        title: L10n.string(.DataManagement.transferRestoreAllData),
                        detail: L10n.string(.DataManagement.transferRestoreScope)
                    ) else { return }
                    try await dataModel.performStorageOperation(.restore(url))
                } else if !isDirectory, url.pathExtension.lowercased() == "json" {
                    let document = try await dataModel.readBackup(from: url)
                    let metadata = SettingsBackupService().metadata(for: document)
                    guard confirmRestore(
                        title: L10n.string(.DataManagement.transferRestoreSettingsTemplates),
                        detail: L10n.string(.DataManagement.transferBackupTimeCurrentSettingsTemplates(String(describing: SettingsBackupPresentation.localizedDateTime(metadata.createdAt))))
                    ) else { dataModel.clearTransferState(); return }
                    try await dataModel.importBackup(document)
                } else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: L10n.string(.DataManagement.transferChooseArckitbackupPackageJsonSettings)])
                }
            } catch { showFailure(L10n.string(.DataManagement.transferBackupRestoreFailed), error) }
        }
    }

    private func confirmRestore(title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string(.Common.restore))
        alert.addButton(withTitle: L10n.string(.Common.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showFailure(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string(.DataManagement.transferGot))
        alert.runModal()
    }
}
