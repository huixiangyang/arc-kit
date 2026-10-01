import ArcKitPersistence
import ArcKitPlatform
import Foundation
import Combine

public enum SettingsTransferState: Equatable {
    case idle
    case working(String)
    case succeeded(String)
    case failed(String)
}

/// 拥有备份、恢复和维护状态，生命周期独立于页面；配置只有 SettingsModel 一份。
@MainActor
public final class DataManagementModel: ObservableObject {
    @Published public private(set) var transferState: SettingsTransferState = .idle
    @Published public private(set) var lastAutomaticBackup: SettingsBackupMetadata?
    @Published public private(set) var automaticBackupMetadataError: String?
    @Published public private(set) var lastExportedBackupURL: URL?
    @Published public private(set) var isLoadingAutomaticBackupMetadata = true
    private let settingsModel: SettingsModel
    private let backupService: SettingsBackupService
    private var backupMetadataGeneration = 0
    private var observations = Set<AnyCancellable>()
    private var operations: SettingsOperationGate { settingsModel.operations }
    var database: ArcKitDatabase { settingsModel.store.database }
    var isOperationRunning: Bool { operations.isBusy }
    var beforeStorageOperation: ((Bool) async throws -> Void)?
    var afterStorageOperation: ((Bool) async -> Void)?

    public init(settingsModel: SettingsModel, backupService: SettingsBackupService = SettingsBackupService()) {
        self.settingsModel = settingsModel
        self.backupService = backupService
        operations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        settingsModel.didReplayHistory.sink { [weak self] in self?.resetFeedback() }.store(in: &observations)
        refreshAutomaticBackupMetadata()
    }

    public func readBackup(from url: URL) async throws -> SettingsBackupDocument {
        let lease = try beginTransferOperation(message: L10n.string(.Settings.saveCheckingBackup))
        defer { operations.end(lease) }
        let service = backupService
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try service.loadDocument(from: url)
            }.value
            transferState = .idle
            return document
        } catch {
            transferState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 页面切换不会销毁任务；数据包、设置 JSON 和重置共用互斥与结果状态。
    func performStorageOperation(_ operation: StorageOperation) async throws {
        guard !settingsModel.isLoading, settingsModel.committedSettings != nil else {
            throw SettingsBackupError.operationInProgress
        }
        let lease = try operations.begin(.storage)
        lastExportedBackupURL = nil
        transferState = .working(operation.progress)
        defer { operations.end(lease) }
        do {
            guard await settingsModel.drainPendingChanges(under: lease) else {
                throw ArcKitDatabaseError.message(L10n.string(.Settings.saveCurrentSettingsUnsavedOperationStopped))
            }
            let service = StorageMaintenance(database: database)
            let result: (message: String, exportedURL: URL?)
            do {
                try await beforeStorageOperation?(operation.isRestore)
                result = try await Task.detached { try operation.perform(using: service) }.value
                if operation.isRestore {
                    try await settingsModel.reloadAfterRestore(under: lease)
                    refreshAutomaticBackupMetadata()
                }
            } catch {
                // 停后台或恢复的任一步失败，都由生命周期层重新接管现存数据。
                await afterStorageOperation?(operation.isRestore)
                throw error
            }
            await afterStorageOperation?(operation.isRestore)
            lastExportedBackupURL = result.exportedURL
            transferState = .succeeded(result.message)
        } catch {
            transferState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    public func exportBackup(to url: URL) async throws -> SettingsBackupMetadata {
        let lease = try beginTransferOperation(message: L10n.string(.Settings.saveExportingSettingsTemplates))
        defer { operations.end(lease) }
        let service = backupService
        let settings = settingsModel.settings
        let version = applicationVersion
        do {
            let metadata = try await Task.detached(priority: .userInitiated) {
                try service.export(settings: settings, applicationVersion: version, to: url)
            }.value
            let exportedURL = url.standardizedFileURL
            lastExportedBackupURL = exportedURL
            transferState = .succeeded(L10n.string(.Settings.saveExportedSettingsCustomTemplatesWritten(String(describing: exportedURL.lastPathComponent))))
            return metadata
        } catch {
            transferState = .failed(error.localizedDescription)
            throw error
        }
    }

    public func importBackup(_ document: SettingsBackupDocument) async throws {
        let lease = try beginTransferOperation(message: L10n.string(.Settings.saveBackingUpCurrentSettingsImporting))
        defer { operations.end(lease) }
        let service = backupService
        let currentSettings = settingsModel.settings
        let version = applicationVersion
        do {
            // 覆盖前先保存当前完整状态，导入失败或用户反悔时仍有真实恢复点。
            let result = try await Task.detached(priority: .userInitiated) {
                let metadata = try service.saveAutomaticBackup(
                    settings: currentSettings,
                    applicationVersion: version
                )
                let materialized = try service.materialize(document)
                return (metadata, materialized)
            }.value
            updateAutomaticBackupMetadata(result.0)
            do {
                try requireUnchangedSettings(currentSettings)
                try await settingsModel.replaceSettingsImmediately(with: result.1.settings, under: lease, historyActionName: L10n.string(.Settings.saveImportSettings))
            } catch {
                service.discard(result.1)
                throw error
            }
            transferState = .succeeded(L10n.string(.Settings.saveSettingsImportedRestorePreviousSettings))
        } catch {
            transferState = .failed(error.localizedDescription)
            throw error
        }
    }

    public func restoreAutomaticBackup() async {
        let lease: SettingsOperationGate.Lease
        do {
            lease = try beginTransferOperation(message: L10n.string(.Settings.saveRestoringLatestBackup))
        } catch {
            return
        }
        defer { operations.end(lease) }
        let service = backupService
        let currentSettings = settingsModel.settings
        let version = applicationVersion
        do {
            // 先把目标备份读进内存，再用当前状态覆盖自动备份；连续恢复即可撤销本次恢复。
            let result = try await Task.detached(priority: .userInitiated) {
                let document = try service.loadAutomaticBackup()
                let materialized = try service.materialize(document)
                do {
                    let metadata = try service.saveAutomaticBackup(
                        settings: currentSettings,
                        applicationVersion: version
                    )
                    return (metadata, materialized, document)
                } catch {
                    service.discard(materialized)
                    throw error
                }
            }.value
            updateAutomaticBackupMetadata(result.0)
            do {
                try requireUnchangedSettings(currentSettings)
                try await settingsModel.replaceSettingsImmediately(with: result.1.settings, under: lease, historyActionName: L10n.string(.Settings.saveRestoreLatestBackup))
            } catch let replacementError {
                service.discard(result.1)
                // 当前设置没有被替换时，原备份也必须恢复并重新发布真实元数据；
                // 二次失败不能吞掉，否则界面会把已经轮换的备份误报为原恢复点。
                do {
                    let restoredMetadata = try service.saveAutomaticDocument(result.2)
                    updateAutomaticBackupMetadata(restoredMetadata)
                } catch let rollbackError {
                    refreshAutomaticBackupMetadata()
                    throw SettingsBackupError.recoveryTransactionFailed(
                        primary: replacementError.localizedDescription,
                        automaticBackupRollback: rollbackError.localizedDescription
                    )
                }
                throw replacementError
            }
            transferState = .succeeded(L10n.string(.Settings.saveLatestBackupRestoredRestoreAgainReturn))
        } catch {
            transferState = .failed(error.localizedDescription)
        }
    }

    public func resetWithAutomaticBackup() async {
        guard !settingsModel.isUsingDefaultSettings else {
            clearTransferState()
            return
        }
        let lease: SettingsOperationGate.Lease
        do {
            lease = try beginTransferOperation(message: L10n.string(.Settings.saveBackingUpRestoringDefaults))
        } catch {
            return
        }
        defer { operations.end(lease) }
        let service = backupService
        let currentSettings = settingsModel.settings
        let version = applicationVersion
        do {
            let metadata = try await Task.detached(priority: .userInitiated) {
                try service.saveAutomaticBackup(settings: currentSettings, applicationVersion: version)
            }.value
            updateAutomaticBackupMetadata(metadata)
            try requireUnchangedSettings(currentSettings)
            try await settingsModel.replaceSettingsImmediately(with: .defaults, under: lease, historyActionName: L10n.string(.Settings.saveRestoreDefaultSettings))
            transferState = .succeeded(L10n.string(.Settings.saveDefaultsRestoredPreviousSettingsBackedUp))
        } catch {
            transferState = .failed(error.localizedDescription)
        }
    }

    public func clearTransferState() {
        guard !operations.isBusy else { return }
        resetFeedback()
    }

    private func resetFeedback() {
        transferState = .idle
        lastExportedBackupURL = nil
    }

    public func exportedBackupURLForReveal(fileManager: FileManager = .default) -> URL? {
        guard let url = lastExportedBackupURL else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: url.path)
        else {
            lastExportedBackupURL = nil
            transferState = .failed(L10n.string(.Settings.saveExportedBackupMovedDeleted))
            return nil
        }
        return url
    }

    public func refreshAutomaticBackupMetadata() {
        backupMetadataGeneration += 1
        let generation = backupMetadataGeneration
        let service = backupService
        isLoadingAutomaticBackupMetadata = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<SettingsBackupMetadata?, Error> in
                Result { try service.inspectAutomaticBackupMetadata() }
            }.value
            guard let self, generation == backupMetadataGeneration else { return }
            switch result {
            case let .success(metadata):
                lastAutomaticBackup = metadata
                automaticBackupMetadataError = nil
            case let .failure(error):
                lastAutomaticBackup = nil
                automaticBackupMetadataError = L10n.string(.Settings.saveBackupReadFailed(String(describing: error.localizedDescription)))
            }
            isLoadingAutomaticBackupMetadata = false
        }
    }

    private func updateAutomaticBackupMetadata(_ metadata: SettingsBackupMetadata) {
        backupMetadataGeneration += 1
        lastAutomaticBackup = metadata
        automaticBackupMetadataError = nil
        isLoadingAutomaticBackupMetadata = false
    }

    private func requireUnchangedSettings(_ expected: AppSettings) throws {
        guard settingsModel.settings == expected else { throw SettingsBackupError.settingsChangedDuringTransfer }
    }

    private func beginTransferOperation(message: String) throws -> SettingsOperationGate.Lease {
        guard !settingsModel.isLoading, settingsModel.committedSettings != nil else {
            throw SettingsBackupError.operationInProgress
        }
        let lease = try operations.begin(.transfer)
        lastExportedBackupURL = nil
        transferState = .working(message)
        return lease
    }

    private var applicationVersion: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "development"
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "development" : normalized
    }
}
