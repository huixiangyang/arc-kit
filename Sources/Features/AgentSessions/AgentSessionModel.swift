import ArcKitPersistence
import ArcKitPlatform
import AppKit
import Combine
import Foundation

@MainActor
final class AgentSessionModel: ObservableObject {
    @Published private(set) var rows: [AgentSessionRow] = []
    @Published private(set) var versions: [AgentSessionVersion] = []
    @Published private(set) var isWorking = false
    @Published private(set) var progress: String?
    @Published private(set) var feedback: String?
    @Published private(set) var failure: String?
    @Published private(set) var sourceErrors: [UUID: String] = [:]
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var lastChecked: Date?
    @Published private(set) var searchResult = AgentSessionSearchResult()
    @Published private(set) var isSearching = false
    @Published private(set) var searchFailure: String?
    private let settings: SettingsModel
    let store: AgentSessionStore
    let isPreview: Bool
    private var configuration = AgentSessionSettings.defaults
    private var observations = Set<AnyCancellable>()
    private var watcher: AgentSessionWatcher?
    private var timer: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var suspended = true
    private var rescanNeeded = false
    private var searchRequest = AgentSessionSearchRequest(text: "", sourceID: nil, project: "")
    private var searchGeneration = 0
    private var searchOwner: UUID?
    private var searchTask: Task<Void, Never>?
    private var searchWorker: Task<AgentSessionSearchResult, Error>?

    init(settings: SettingsModel, isPreview: Bool = false) {
        self.settings = settings; self.isPreview = isPreview
        store = AgentSessionStore(database: settings.store.database)
        settings.operations.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.suspended else { return }
                if settings.operations.isBusy { self.cancelSearch(); return }
                if self.rescanNeeded { self.refresh(backup: self.configuration.isEnabled) }
                else { self.searchBackups(self.searchRequest, owner: self.searchOwner) }
            }
        }.store(in: &observations)
        settings.$committedSettings.compactMap { $0?.agentSessions }.removeDuplicates().sink { [weak self] in self?.apply($0) }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.configuration.isEnabled, !self.suspended else { return }
                self.refresh(backup: true)
            }
        }.store(in: &observations)
    }
    func start() {
        suspended = false; configureMonitoring()
        refresh(backup: configuration.isEnabled)
    }
    func stop() {
        suspended = true; watcher = nil; timer?.cancel(); timer = nil; debounce?.cancel(); debounce = nil
        cancelSearch()
    }
    func suspendAndWait() async {
        stop()
        await task?.value
        // 数据恢复/退出必须等待索引写者结束，不能关闭它仍在使用的数据库。
        _ = try? await searchWorker?.value
    }
    private func apply(_ value: AgentSessionSettings) {
        configuration = value
        guard !suspended else { return }
        configureMonitoring(); refresh(backup: value.isEnabled)
    }
    private func configureMonitoring() {
        watcher = nil; timer?.cancel(); debounce?.cancel()
        guard !suspended, configuration.isEnabled else { return }
        // 调试模式允许显式选择的样本目录，绝不自动添加或扫描用户的默认 Home。
        watcher = AgentSessionWatcher(paths: configuration.sources.flatMap { [$0.path] + $0.attachmentRoots }) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.refresh(backup: true)
            }
        }
    }
    private func scheduleChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.refresh(backup: true)
        }
    }
    func refresh(backup: Bool = false, keys: Set<AgentSessionKey>? = nil, preservingFeedback: Bool = false) {
        guard !suspended, !isWorking, !settings.operations.isBusy else { rescanNeeded = true; return }
        let config = configuration; let store = store; let previousRows = rows
        begin(L10n.string(backup ? .AgentSessions.progressBackup : .AgentSessions.progressScan), clearFeedback: !preservingFeedback)
        task = Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try store.recoverJobs()
                    let adapter = CodexSessionAdapter()
                    let scan = try adapter.scan(config.sources, previous: previousRows)
                    let job = try store.beginJob(backup ? "backup" : "scan")
                    do {
                        var saved = 0
                        var failures = scan.sourceErrors
                        if backup {
                            var wanted = keys ?? Set(scan.rows.map(\.key))
                            var lastCount = -1
                            while lastCount != wanted.count {
                                lastCount = wanted.count
                                for row in scan.rows where wanted.contains(row.key) {
                                    for id in row.metadata.childIDs + [row.metadata.parentID].compactMap({ $0 }) { wanted.insert(.init(sourceID: row.key.sourceID, sessionID: id)) }
                                }
                            }
                            let previous = try store.versions(); let capturedAt = Date()
                            var changed = Set(scan.rows.filter { row in
                                guard let old = previous.first(where: { $0.key == row.key }) else { return true }
                                return old.metadata != row.metadata || !old.complete
                            }.map(\.key))
                            var familyCheckpoints = Set<AgentSessionKey>()
                            var count = -1
                            while count != changed.count {
                                count = changed.count
                                for row in scan.rows where row.metadata.childIDs.contains(where: { changed.contains(.init(sourceID: row.key.sourceID, sessionID: $0)) }) {
                                    changed.insert(row.key); familyCheckpoints.insert(row.key)
                                }
                            }
                            // 首次全量采集优先最近活动，容量不足时先保护当前工作。
                            for row in scan.rows.sorted(by: { $0.metadata.modifiedAt > $1.metadata.modifiedAt }) where wanted.contains(row.key) {
                                try Task.checkCancellation()
                                guard let source = config.sources.first(where: { $0.id == row.key.sourceID }) else { continue }
                                // 已完整保护的未变化文件不再次复制。原生标题/归档变化也会创建新版本。
                                if let old = previous.first(where: { $0.key == row.key }), old.metadata == row.metadata, old.complete, !familyCheckpoints.contains(row.key) { continue }
                                do {
                                    var payload = try adapter.capture(row, source: source); payload.capturedAt = capturedAt
                                    let available = Set(scan.rows.map(\.key) + previous.map(\.key))
                                    payload.missingRelatedIDs = (row.metadata.childIDs + [row.metadata.parentID].compactMap { $0 }).filter { !available.contains(.init(sourceID: row.key.sourceID, sessionID: $0)) }
                                    let version = try store.save(payload, capacityBytes: Int64(config.capacityGB) * 1_024 * 1_024 * 1_024, forceCheckpoint: familyCheckpoints.contains(row.key))
                                    if !previous.contains(where: { $0.id == version.id }) { saved += 1 }
                                } catch { failures[source.id] = error.localizedDescription }
                            }
                            try store.prune(days: config.retentionDays)
                        }
                        let archived = try store.archivedRows()
                        var merged = scan.rows
                        for saved in archived {
                            if let index = merged.firstIndex(where: { $0.key == saved.key }) { merged[index].latest = saved.latest }
                            else {
                                var row = saved
                                row.sourceMissing = scan.scannedSources.contains(saved.key.sourceID)
                                row.sourcePath = config.sources.first(where: { $0.id == saved.key.sourceID })?.path
                                merged.append(row)
                            }
                        }
                        merged.sort { $0.metadata.modifiedAt > $1.metadata.modifiedAt }
                        try store.finishJob(job, result: failures.isEmpty ? "complete" : "partial", detail: "saved=\(saved); sourceErrors=\(failures.count)")
                        return (merged, try store.versions(), try store.byteCount(), failures, saved)
                    } catch {
                        try store.finishJob(job, result: "failed", detail: error.localizedDescription)
                        throw error
                    }
                }.value
                rows = result.0; versions = result.1; bytes = result.2; sourceErrors = result.3; lastChecked = Date()
                if backup { feedback = L10n.string(.AgentSessions.resultBackup(String(result.4))) }
            } catch { failure = error.localizedDescription }
            finish()
        }
    }
    func payloads(for selected: [AgentSessionVersion]) async throws -> [AgentSessionPayload] {
        let versions = versions; let store = store
        return try await Task.detached(priority: .userInitiated) {
            var chosen: [AgentSessionKey: AgentSessionVersion] = [:]
            var pending = selected
            while let version = pending.popLast() {
                if chosen[version.key] != nil { continue }; chosen[version.key] = version
                for id in version.metadata.childIDs + [version.metadata.parentID].compactMap({ $0 }) {
                    let key = AgentSessionKey(sourceID: version.key.sourceID, sessionID: id)
                    guard let related = versions.first(where: { $0.key == key && $0.capturedAt <= version.capturedAt }) else { throw AgentSessionError.missingRelated }
                    pending.append(related)
                }
            }
            return try chosen.values.sorted { $0.metadata.createdAt < $1.metadata.createdAt }.map { try store.payload($0, verifyIntegrity: true) }
        }.value
    }
    func perform(_ label: String, action: @escaping @Sendable () throws -> String) {
        guard !isWorking, !settings.operations.isBusy, !suspended else { return }
        begin(label)
        task = Task {
            do { feedback = try await Task.detached(priority: .userInitiated, operation: action).value }
            catch { failure = error.localizedDescription }
            finish(schedulePending: false); refresh(preservingFeedback: true)
        }
    }
    func setRetained(_ version: AgentSessionVersion, _ retained: Bool) {
        let store = store
        perform(L10n.string(.AgentSessions.progressSave)) { try store.retain(version, value: retained); return L10n.string(.AgentSessions.resultSaved) }
    }
    func importArchive(_ url: URL, password: String) {
        let store = store; let limit = Int64(configuration.capacityGB) * 1_024 * 1_024 * 1_024
        perform(L10n.string(.AgentSessions.progressImport)) {
            let payloads = try AgentSessionArchive.load(from: url, password: password)
            // 所有条目先校验再发布；不触碰原工具或自动添加来源。
            for payload in payloads { _ = try payload.validated() }
            _ = try store.saveBatch(payloads, capacityBytes: limit)
            return L10n.string(.AgentSessions.resultImport(String(payloads.count)))
        }
    }
    func searchBackups(_ request: AgentSessionSearchRequest, owner: UUID? = nil) {
        searchRequest = request; searchOwner = owner
        cancelSearch()
        searchResult = .init(); searchFailure = nil
        guard !suspended, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        guard !isWorking, !settings.operations.isBusy else { return }
        let generation = searchGeneration, previous = searchWorker, store = store
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                // 上一个查询已被取消，先等它结束再启动下一个，至多一个索引写者。
                _ = try? await previous?.value
                try Task.checkCancellation()
                guard let self, !self.suspended, self.searchGeneration == generation else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    try store.prepareSearchIndex()
                    return try store.search(request)
                }
                self.searchWorker = worker
                let result = try await worker.value
                guard !Task.isCancelled, self.searchGeneration == generation, !self.suspended else { return }
                self.searchResult = result; self.isSearching = false; self.searchWorker = nil
            } catch {
                guard let self, !Task.isCancelled, self.searchGeneration == generation, !self.suspended else { return }
                if !(error is CancellationError) { self.searchFailure = error.localizedDescription }
                self.isSearching = false; self.searchWorker = nil
            }
        }
    }
    /// 页面重建后旧页面可能迟到消失，只能结束它自己发起的查询。
    func endSearch(owner: UUID) {
        guard searchOwner == owner else { return }
        searchBackups(.init(text: "", sourceID: nil, project: ""))
    }
    func waitUntilSearchFinishes() async { await searchTask?.value }
    private func cancelSearch() {
        searchGeneration += 1; searchTask?.cancel(); searchTask = nil; searchWorker?.cancel(); isSearching = false; searchResult = .init()
    }
    func clearFeedback() { feedback = nil; failure = nil }
    func waitUntilIdle() async { while let pending = task { await pending.value } }
    private func begin(_ label: String, clearFeedback: Bool = true) {
        cancelSearch()
        isWorking = true; progress = label; rescanNeeded = false
        if clearFeedback { failure = nil; feedback = nil }
    }
    private func finish(schedulePending: Bool = true) {
        isWorking = false; progress = nil; task = nil
        if schedulePending && rescanNeeded && !suspended { rescanNeeded = false; refresh(backup: configuration.isEnabled) }
        else if !suspended { searchBackups(searchRequest, owner: searchOwner) }
    }
}
