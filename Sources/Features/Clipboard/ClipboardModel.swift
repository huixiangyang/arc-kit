import ArcKitPlatform
import AppKit
@preconcurrency import CloudKit
import Combine
import Foundation

enum ClipboardSyncStatus: Equatable {
    case off, unavailable, approval, working, pending, synced(Date), failed(String)
    var text: String {
        switch self {
        case .off: L10n.string(.Clipboard.syncOff)
        case .unavailable: L10n.string(.Clipboard.unavailable)
        case .approval: L10n.string(.Clipboard.connectHint)
        case .working: L10n.string(.Clipboard.syncing)
        case .pending: L10n.string(.Clipboard.pending)
        case .synced(let date): L10n.string(.Clipboard.synced(L10n.time(date)))
        case .failed(let message): message
        }
    }
}

/// 主应用唯一拥有采集、同步与历史面板；关闭设置窗口不会停止已开启的记录。
@MainActor
final class ClipboardModel: ObservableObject {
    @Published private(set) var items: [ClipboardSummary] = []
    @Published private(set) var selectedItem: ClipboardItem?
    @Published private(set) var sources: [ClipboardSource] = []
    @Published private(set) var syncStatus: ClipboardSyncStatus = .off
    @Published private(set) var message: String?
    @Published private(set) var shortcutError: String?
    @Published private(set) var busy = false
    @Published private(set) var settings = ClipboardSettings.defaults
    var search = ""
    var favoritesOnly = false
    var sourceFilter: String?
    var showHistory: (() -> Void)?
    var closeHistory: (() -> Void)?
    let isPreview: Bool
    let store: ClipboardStore
    private let gate: SettingsOperationGate
    private let system: ClipboardSystemAccess?
    private let cloud: (any ClipboardCloudTransport)?
    private let hotKey = ClipboardHotKey()
    private var selectedID: String?
    private var accountID: String?
    private var runTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var reads = 0
    private var lastChange = 0
    private var started = false
    private var recordingShortcut = false
    private var observation: AnyCancellable?
    private var accountObservation: AnyCancellable?
    private var retryAfter = Date.distantPast
    var cloudConfigured: Bool { cloud != nil }

    init(store: ClipboardStore, settingsModel: SettingsModel, isPreview: Bool = false,
         cloud: (any ClipboardCloudTransport)? = nil, system: ClipboardSystemAccess? = nil) {
        self.store = store; self.gate = settingsModel.operations; self.isPreview = isPreview
        self.system = isPreview ? nil : (system ?? ClipboardSystemAccess())
        if let cloud { self.cloud = cloud }
        else if !isPreview, let identifier = ClipboardCloudConfiguration.containerIdentifier() {
            self.cloud = NativeClipboardCloud(identifier: identifier, paths: store.database.paths)
        } else { self.cloud = nil }
        observation = settingsModel.$committedSettings.compactMap { $0?.clipboard }.removeDuplicates().sink { [weak self] settings in
            Task { @MainActor in self?.apply(settings) }
        }
        // 本地发行不监听云账户变化，也不触碰云端账户分区。
        if !isPreview, self.cloud != nil {
            accountObservation = NotificationCenter.default.publisher(for: .CKAccountChanged).sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    syncTask?.cancel(); accountID = nil; selectedItem = nil; items = []; sources = []
                    // 不在存储恢复期间写旧库；下一次同步仍会核对账号身份。
                    if !gate.isBusy { do { try store.revokeApproval() } catch { message = error.localizedDescription } }
                    syncStatus = .approval
                    reload()
                }
            }
        }
    }

    private func apply(_ value: ClipboardSettings) {
        let wasEnabled = settings.isEnabled
        if settings.syncScope != value.syncScope { syncTask?.cancel() }
        settings = value
        if !value.syncEnabled { syncTask?.cancel(); syncStatus = .off }
        else if cloud == nil { syncStatus = .unavailable }
        if value.isEnabled && !wasEnabled { lastChange = system?.changeCount ?? 0 }
        if started { registerShortcut(); synchronize() }
    }

    func start() {
        guard !started, !isPreview else { return }
        started = true; lastChange = system?.changeCount ?? 0
        registerShortcut()
        runTask = Task { [weak self] in
            guard let self else { return }
            do { accountID = try store.state().account; reload() }
            catch { message = error.localizedDescription }
            var lastMaintenance = Date.distantPast
            while !Task.isCancelled {
                capture()
                if Date().timeIntervalSince(lastMaintenance) >= 60, !gate.isBusy, !busy {
                    lastMaintenance = Date()
                    let days = settings.retentionDays
                    mutate { store, account in try store.prune(account: account, days: days) }
                    synchronize()
                }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { break }
            }
        }
    }

    func stop() {
        started = false
        runTask?.cancel(); syncTask?.cancel(); readTask?.cancel(); hotKey.stop()
        closeHistory?()
    }

    /// 完整备份/恢复前等待正在落盘的记录，恢复后不会接收旧云请求的回包。
    func suspend() async {
        stop()
        await runTask?.value; await syncTask?.value; await writeTask?.value; await readTask?.value
        runTask = nil; syncTask = nil; writeTask = nil; readTask = nil
    }

    private func capture() {
        guard settings.isEnabled, !gate.isBusy, !busy, let system else { return }
        let change = system.changeCount
        guard change != lastChange else { return }
        lastChange = change
        do {
            guard let item = try system.read(settings: settings) else { return }
            mutate { store, account in try store.insert(item, account: account) }
        } catch { message = error.localizedDescription }
    }

    func reload() {
        reads += 1; let generation = reads
        readTask?.cancel()
        let store = store, account = accountID, query = search, favorites = favoritesOnly, source = sourceFilter, selected = selectedID
        readTask = Task { [weak self] in
            do {
                let result = try await Task.detached {
                    let items = try store.list(account: account, search: query, favorites: favorites, source: source)
                    let id = items.contains(where: { $0.id == selected }) ? selected : items.first?.id
                    let detail = try id.flatMap { try store.item(id: $0, account: account) }
                    return (items, detail, try store.sources(account: account))
                }.value
                guard let self, !Task.isCancelled, reads == generation else { return }
                items = result.0; selectedItem = result.1; selectedID = result.1?.id; sources = result.2
            } catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
        }
    }

    func select(_ id: String?) { selectedID = id; reload() }
    func favorite(_ id: String, value: Bool) { mutate { try $0.setFavorite(id: id, account: $1, value: value) } }
    func delete(_ id: String) { mutate { try $0.deleteEverywhere(id: id, account: $1) } }
    func clearLocal() { mutate { try $0.clearLocal(account: $1) } }
    func clearMessage() { message = nil }

    private func mutate(_ action: @escaping @Sendable (ClipboardStore, String?) throws -> Void) {
        guard !gate.isBusy, !busy else { message = L10n.string(.Clipboard.busy); return }
        busy = true
        let store = store, account = accountID
        writeTask = Task { [weak self] in
            defer { self?.busy = false; self?.reload() }
            do { try await Task.detached { try action(store, account) }.value }
            catch { self?.message = error.localizedDescription }
        }
    }

    func copySelected(plain: Bool = false) {
        guard let content = selectedItem?.content, let system else { return }
        do { try system.copy(content, plain: plain); message = L10n.string(.Clipboard.copied) }
        catch { message = error.localizedDescription }
    }

    func pasteSelected(plain: Bool = false, target: NSRunningApplication?) {
        guard let content = selectedItem?.content, let system else { return }
        closeHistory?()
        Task {
            do { try await system.paste(content, plain: plain, target: target) }
            catch { message = error.localizedDescription; showHistory?() }
        }
    }

    func saveSelectedToFinder(markdown: Bool = false) {
        guard let content = selectedItem?.content, let system else { return }
        do {
            let directory = try system.finderDirectory()
            Task {
                do {
                    let url = try await Task.detached { try ClipboardFileWriter.save(content, directory: directory, markdown: markdown) }.value
                    message = L10n.string(.Clipboard.saved(url.lastPathComponent))
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }

    func saveSelectedAs() {
        guard let content = selectedItem?.content, !isPreview else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = L10n.string(.Clipboard.saveHere)
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                do {
                    let url = try await Task.detached { try ClipboardFileWriter.save(content, directory: directory) }.value
                    self?.message = L10n.string(.Clipboard.saved(url.lastPathComponent))
                } catch { self?.message = error.localizedDescription }
            }
        }
    }

    func shortcutRecording(_ active: Bool) { recordingShortcut = active; registerShortcut() }
    private func registerShortcut() {
        guard !isPreview, started, !recordingShortcut else { hotKey.stop(); return }
        let status = hotKey.register(settings.shortcut) { [weak self] in self?.showHistory?() }
        shortcutError = status == 0 ? nil : L10n.string(.Clipboard.shortcutFailure(String(status)))
    }

    @discardableResult
    func synchronize(approve: Bool = false) -> Task<Void, Never>? {
        guard !isPreview, started, settings.syncEnabled else { return nil }
        guard let cloud else { syncStatus = .unavailable; return nil }
        guard syncTask == nil, !gate.isBusy, approve || Date() >= retryAfter else { return nil }
        let store = store, scope = settings.syncScope
        syncStatus = .working
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { syncTask = nil; reload() }
            do {
                let current = try await cloud.account()
                try Task.checkCancellation(); guard !gate.isBusy else { throw ClipboardError.busy }
                let state = try store.state()
                if approve { try store.approve(account: current) }
                else if state.account != current || !state.approved {
                    try store.revokeApproval(); accountID = state.account == current ? current : nil
                    syncStatus = .approval; return
                }
                accountID = current
                try await cloud.prepare()
                try Task.checkCancellation()
                var token = try store.state().token
                var more = true
                while more {
                    let page = try await cloud.fetch(token: token)
                    try Task.checkCancellation(); guard !gate.isBusy else { throw ClipboardError.busy }
                    guard try await cloud.account() == current else { throw ClipboardError.accountChanged }
                    try Task.checkCancellation()
                    try await Task.detached {
                        try store.merge(page.changes, removed: page.removed, token: page.token, account: current)
                    }.value
                    token = page.token; more = page.more
                }
                // 每轮有界批次，离线积压不会长期占住 UI/恢复流程；下一轮继续处理。
                for _ in 0..<10 {
                    try Task.checkCancellation(); guard !gate.isBusy else { throw ClipboardError.busy }
                    let uploads = try await Task.detached { try store.pending(account: current, scope: scope) }.value
                    if uploads.isEmpty { break }
                    guard try await cloud.account() == current else { throw ClipboardError.accountChanged }
                    try Task.checkCancellation()
                    let receipt = try await cloud.save(uploads)
                    try Task.checkCancellation(); guard !gate.isBusy else { throw ClipboardError.busy }
                    guard try await cloud.account() == current else { throw ClipboardError.accountChanged }
                    try Task.checkCancellation()
                    try await Task.detached {
                        try store.merge(receipt.changes, token: nil, account: current, advanceToken: false)
                    }.value
                    if let failure = receipt.failure { throw failure }
                    if receipt.changes.count < uploads.count { throw ClipboardError.invalidCloudRecord }
                }
                try Task.checkCancellation()
                let remaining = try await Task.detached { try store.pending(account: current, scope: scope).isEmpty }.value
                try Task.checkCancellation()
                syncStatus = remaining ? .synced(Date()) : .pending
                retryAfter = .distantPast
            } catch is CancellationError { }
            catch ClipboardError.accountChanged {
                accountID = nil
                if !gate.isBusy { try? store.revokeApproval() }
                syncStatus = .approval
            } catch {
                if case ClipboardError.signedOut = error {
                    accountID = nil
                    if !gate.isBusy { try? store.revokeApproval() }
                }
                if let cloudError = error as? CKError {
                    if cloudError.code == .notAuthenticated {
                        accountID = nil
                        if !gate.isBusy { try? store.revokeApproval() }
                    }
                    retryAfter = Date().addingTimeInterval(max(60, cloudError.retryAfterSeconds ?? 0))
                    syncStatus = .failed(L10n.string(.Clipboard.syncFailure(String(cloudError.errorCode))))
                } else { retryAfter = Date().addingTimeInterval(60); syncStatus = .failed(error.localizedDescription) }
            }
        }
        return syncTask
    }
}
