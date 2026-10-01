import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation

import Combine

public enum SettingsPersistenceState: Equatable {
    case pending
    case saved(Date?)
    case failed(String)
}

private struct SettingsHistoryEntry {
    var before: AppSettings
    var after: AppSettings
    var actionName: String
    var coalescingKey: String?
    var changedAt: Date
}

@MainActor
public final class SettingsModel: ObservableObject {
    @Published public private(set) var settings: AppSettings
    /// 运行时只订阅已提交配置；编辑草稿和失败事务不得越过此边界。
    @Published public private(set) var committedSettings: AppSettings?
    @Published public private(set) var persistenceState: SettingsPersistenceState = .saved(nil)
    @Published public private(set) var undoActionName: String?
    @Published public private(set) var redoActionName: String?

    @Published public private(set) var committedRevision: StorageRevision?
    @Published public private(set) var isLoading = true
    // 编辑、历史、数据管理与退出共用同一门禁，禁止各自维护互不知情的 busy 标志。
    let operations = SettingsOperationGate()
    var isOperationRunning: Bool { operations.isBusy }
    let didReplayHistory = PassthroughSubject<Void, Never>()
    private var operationObservation: AnyCancellable?
    func waitForPendingChanges() async { await saveTask?.value }
    private var saveTask: Task<Void, Never>?
    let store: SettingsRepository
    let templateLibrary: NewFileTemplateLibrary
    private let saveSubject = PassthroughSubject<AppSettings, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var undoHistory: [SettingsHistoryEntry] = []
    private var redoHistory: [SettingsHistoryEntry] = []
    private let historyLimit: Int
    private let historyCoalescingInterval: TimeInterval
    private let historyNow: () -> Date

    public init(
        store: SettingsRepository = SettingsRepository(),
        templateLibrary: NewFileTemplateLibrary = NewFileTemplateLibrary(),
        historyLimit: Int = 50,
        historyCoalescingInterval: TimeInterval = 0.8,
        historyNow: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.templateLibrary = templateLibrary
        self.historyLimit = max(1, historyLimit)
        self.historyCoalescingInterval = max(0, historyCoalescingInterval)
        self.historyNow = historyNow
        self.settings = Self.normalizedDefaultSettings
        self.committedSettings = nil

        operationObservation = operations.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        setupDebounce()
        reload()
    }

    // 页面只持有各自功能的投影；投影不新建 repository 或独立保存任务。
    lazy var finderEditor = editor(for: \.finder)
    lazy var windowEditor = editor(for: \.windowManagement)
    lazy var mouseEditor = editor(for: \.mouseEnhancement)

    private func editor<Value: Equatable>(for keyPath: WritableKeyPath<AppSettings, Value>) -> SettingsEditor<Value> {
        SettingsEditor(changes: objectWillChange,
            read: { [unowned self] in settings[keyPath: keyPath] },
            committed: { [unowned self] in committedSettings?[keyPath: keyPath] },
            update: { [unowned self] actionName, coalescingKey, change in
                update(actionName: actionName, coalescingKey: coalescingKey) { change(&$0[keyPath: keyPath]) }
            })
    }

    private func setupDebounce() {
        saveSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.persist(settings)
            }
            .store(in: &cancellables)
    }

    public func reload() {
        guard !operations.isBusy else { return }
        enqueueReload()
    }

    func reloadAfterRestore(under operation: SettingsOperationGate.Lease) async throws {
        guard operations.owns(operation) else { throw SettingsBackupError.operationInProgress }
        enqueueReload()
        await waitForPendingChanges()
        if case .failed(let message) = persistenceState { throw ArcKitDatabaseError.message(message) }
    }

    private func enqueueReload() {
        cancelPendingSave()
        let previous = saveTask
        let store = store
        isLoading = true
        saveTask = Task { [weak self] in
            await previous?.value
            let result = await Task.detached { Result { try store.loadSnapshot() } }.value
            guard let self else { return }
            isLoading = false
            switch result {
            case .success(let snapshot):
                settings = snapshot.settings; clearHistory()
                publish(snapshot)
            case .failure(let error): persistenceState = .failed(error.localizedDescription)
            }
        }
    }

    private func publish(_ snapshot: CommittedSettings) {
        if settings == snapshot.settings { persistenceState = .saved(Date()) }
        committedRevision = snapshot.revision
        committedSettings = snapshot.settings
    }

    /// 退出必须等到最后一次事务完成，不能在 applicationWillTerminate 中发起异步写入。
    public func finishPendingChanges() async -> Bool {
        guard let operation = try? operations.begin(.commit) else { return false }
        defer { operations.end(operation) }
        return await drainPendingChanges(under: operation)
    }

    /// 只有持有门禁的调用者可排空提交，数据恢复与卸载不能绕开其他任务。
    func drainPendingChanges(under operation: SettingsOperationGate.Lease) async -> Bool {
        guard operations.owns(operation) else { return false }
        for _ in 0..<8 {
            await saveTask?.value
            guard committedSettings != nil else { return false }
            cancelPendingSave()
            persist(settings)
            await saveTask?.value
            if case .failed = persistenceState { return false }
            if settings == committedSettings { return true }
            // 系统回执可能生成回滚草稿，退出前也要提交这份最终值。
        }
        return false
    }

    public func update(
        actionName: String? = nil,
        coalescingKey: String? = nil,
        recordsHistory: Bool = true,
        _ transform: (inout AppSettings) -> Void
    ) {
        guard !isLoading, committedSettings != nil, (!operations.isBusy || !recordsHistory) else { return }
        var next = settings
        transform(&next)
        next.finder.menuConfiguration.sortAndNormalizeOrders()
        guard validatedRoundTrip(next) else {
            let message = L10n.string(.Settings.saveValidationFailed)
            persistenceState = .failed(message)
            ArcKitLog.append("settings update rejected reason=round-trip-validation")
            return
        }
        guard next != settings else { return }
        if recordsHistory {
            recordHistory(
                before: settings,
                after: next,
                // 默认文案在所属模块内解析，不把内部资源符号暴露到公共参数中。
                actionName: actionName ?? L10n.string(.Settings.saveChangeSettings),
                coalescingKey: coalescingKey
            )
        } else {
            clearHistory()
        }
        settings = next
        persistenceState = .pending
        saveSubject.send(settings)
    }

    public func flush() {
        guard !operations.isBusy else { return }
        cancelPendingSave()
        persist(settings)
    }

    public var canUndo: Bool { !operations.isBusy && !isLoading && !undoHistory.isEmpty }
    public var canRedo: Bool { !operations.isBusy && !isLoading && !redoHistory.isEmpty }
    public var isUsingDefaultSettings: Bool { settings == Self.normalizedDefaultSettings }

    private static var normalizedDefaultSettings: AppSettings {
        var defaults = AppSettings.defaults
        defaults.finder.menuConfiguration.sortAndNormalizeOrders()
        return defaults
    }

    public var undoMenuTitle: String {
        undoActionName.map { L10n.string(.Settings.saveUndo(String(describing: $0))) } ?? L10n.string(.Common.undo)
    }

    public var redoMenuTitle: String {
        redoActionName.map { L10n.string(.Settings.saveRedo(String(describing: $0))) } ?? L10n.string(.Common.redo)
    }

    public func undo() {
        guard canUndo else { return }
        guard let operation = try? operations.begin(.history) else { return }
        Task {
            defer { operations.end(operation) }
            guard let entry = undoHistory.popLast() else { return }
            do {
                try await replaceSettingsImmediately(with: entry.before, under: operation)
                redoHistory.append(entry)
                didReplayHistory.send()
                publishHistoryState()
            } catch {
                undoHistory.append(entry)
                publishHistoryState()
                persistenceState = .failed(L10n.string(.Settings.saveUndoFailed(String(describing: error.localizedDescription))))
            }
        }
    }

    public func redo() {
        guard canRedo else { return }
        guard let operation = try? operations.begin(.history) else { return }
        Task {
            defer { operations.end(operation) }
            guard let entry = redoHistory.popLast() else { return }
            do {
                try await replaceSettingsImmediately(with: entry.after, under: operation)
                undoHistory.append(entry)
                didReplayHistory.send()
                publishHistoryState()
            } catch {
                redoHistory.append(entry)
                publishHistoryState()
                persistenceState = .failed(L10n.string(.Settings.saveRedoFailed(String(describing: error.localizedDescription))))
            }
        }
    }

    public func isOwnRepository(_ source: SettingsRepository?) -> Bool {
        guard let source else { return false }
        return source === store
    }

    private func persist(_ candidate: AppSettings) {
        guard committedSettings != nil, !isLoading, validatedRoundTrip(candidate) else { return }
        let previous = saveTask
        let store = store
        saveTask = Task { [weak self] in
            await previous?.value
            let result = await Task.detached { Result { try store.save(candidate) } }.value
            guard let self else { return }
            switch result {
            case .success(let snapshot): publish(snapshot)
            case .failure(let error): persistenceState = .failed(error.localizedDescription)
            }
        }
    }

    private func validatedRoundTrip(_ settings: AppSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return false }
        return decoded == settings
    }

    func replaceSettingsImmediately(
        with candidate: AppSettings,
        under operation: SettingsOperationGate.Lease,
        historyActionName: String? = nil
    ) async throws {
        guard operations.owns(operation) else { throw SettingsBackupError.operationInProgress }
        var next = candidate
        next.finder.menuConfiguration.sortAndNormalizeOrders()
        guard validatedRoundTrip(next) else {
            throw SettingsBackupError.invalidDocument(L10n.string(.Settings.saveImportedSettingsFullValidationFailed))
        }
        // 导入、恢复和重置会替换整份设置；必须先取消旧的 300ms 防抖保存，
        // 否则旧快照可能在替换完成后重新写回磁盘。
        let previous = settings
        cancelPendingSave()
        await saveTask?.value
        // 已在途的提交可能触发登录项失败回滚；不能用导入前的草稿覆盖系统刚确认的状态。
        guard settings == previous else { throw SettingsBackupError.settingsChangedDuringTransfer }
        let store = store
        let candidate = next
        let snapshot = try await Task.detached { try store.save(candidate) }.value

        settings = next
        if let historyActionName, previous != next {
            recordHistory(
                before: previous,
                after: next,
                actionName: historyActionName,
                coalescingKey: nil
            )
        }
        publish(snapshot)
    }

    private func cancelPendingSave() {
        cancellables.removeAll()
        setupDebounce()
    }

    private func recordHistory(
        before: AppSettings,
        after: AppSettings,
        actionName: String,
        coalescingKey: String?
    ) {
        let normalizedName = actionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = normalizedName.isEmpty ? L10n.string(.Settings.saveChangeSettings) : normalizedName
        let now = historyNow()
        if let coalescingKey,
           var last = undoHistory.last,
           last.coalescingKey == coalescingKey,
           now.timeIntervalSince(last.changedAt) >= 0,
           now.timeIntervalSince(last.changedAt) <= historyCoalescingInterval {
            _ = undoHistory.removeLast()
            if last.before != after {
                last.after = after
                last.actionName = resolvedName
                last.changedAt = now
                undoHistory.append(last)
            }
        } else {
            undoHistory.append(SettingsHistoryEntry(
                before: before,
                after: after,
                actionName: resolvedName,
                coalescingKey: coalescingKey,
                changedAt: now
            ))
            if undoHistory.count > historyLimit {
                undoHistory.removeFirst(undoHistory.count - historyLimit)
            }
        }
        redoHistory.removeAll()
        publishHistoryState()
    }

    private func clearHistory() {
        undoHistory.removeAll()
        redoHistory.removeAll()
        publishHistoryState()
    }

    private func publishHistoryState() {
        undoActionName = undoHistory.last?.actionName
        redoActionName = redoHistory.last?.actionName
    }

}
