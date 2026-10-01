import ArcKitPlatform
import AppKit
import Combine

@MainActor
public final class AppBackgroundModel: ObservableObject {
    @Published private(set) var settings = AppBackgroundSettings()
    @Published private(set) var image: NSImage?
    @Published private(set) var videoURL: URL?
    @Published private(set) var isLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var persistenceState: SettingsPersistenceState = .saved(nil)
    @Published private(set) var imageError: String?
    @Published private(set) var isWindowVisible = false
    let playback = AuraPlaybackClock()
    @Published private(set) var undoSettings: AppBackgroundSettings?
    private let store: AppBackgroundStore
    private var work: Task<Void, Never>?
    private var revision = UUID()
    private var committed = AppBackgroundSettings()
    private var failedImageURL: URL?
    var hasUnsavedChanges: Bool { settings != committed }

    func setWindowVisible(_ visible: Bool) {
        if isWindowVisible != visible { isWindowVisible = visible }
    }

    init(store: AppBackgroundStore) {
        self.store = store
        reload()
    }

    func reload() {
        guard !isBusy else { return }
        work?.cancel()
        let previous = work
        let token = UUID(); revision = token
        isBusy = true
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if revision == token { isBusy = false; work = nil } }
            do {
                let snapshot = try await store.load()
                guard revision == token else { return }
                accept(snapshot)
                isLoaded = true
                persistenceState = .saved(nil)
            } catch { persistenceState = .failed(error.localizedDescription) }
        }
    }

    func update(_ change: (inout AppBackgroundSettings) -> Void) {
        guard isLoaded, !isBusy else { return }
        var next = settings; change(&next)
        if undoSettings == nil { undoSettings = settings }
        do { settings = try next.validated() }
        catch { persistenceState = .failed(error.localizedDescription); return }
        failedImageURL = nil
        save()
    }

    func clearImage() {
        update { $0.style = .aura; $0.imageID = nil; $0.imageName = nil; $0.videoFilename = nil }
    }

    func selectTheme(_ id: String) { update { $0.style = .aura; $0.aura.select(id) } }

    func editTheme(dark: Bool, _ change: (inout AuraTheme) -> Void) {
        update { settings in
            var theme = settings.aura.resolved(in: settings.themes, dark: dark)
            change(&theme)
            settings.aura.select(theme.id)
            settings.aura.draft = theme
        }
    }

    func restoreTheme(dark: Bool) {
        let id = settings.aura.resolvedID(at: Date(), dark: dark)
        update { $0.aura.select(id); $0.opacity = 0.75; $0.dimming = 0.2 }
    }

    func undoAdjustment() {
        guard var previous = undoSettings else { return }
        // 撤销外观调整不撤销个人主题的保存、删除或收藏。
        previous.themes = settings.themes
        previous.aura.favorites = settings.aura.favorites
        let ids = AuraTheme.builtinIDs.union(previous.themes.map(\.id))
        if !ids.contains(previous.aura.themeID) { previous.aura.select("amber") }
        if !ids.contains(previous.aura.dayThemeID) { previous.aura.dayThemeID = "amber" }
        if !ids.contains(previous.aura.nightThemeID) { previous.aura.nightThemeID = "ink" }
        update { $0 = previous }
        undoSettings = nil
    }

    func saveTheme(name: String, dark: Bool) {
        var theme = settings.aura.resolved(in: settings.themes, dark: dark)
        theme.id = UUID().uuidString
        theme.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addTheme(theme)
    }

    func addTheme(_ theme: AuraTheme) {
        guard settings.themes.count < 60 else { showImportError(AppBackgroundError.message(L10n.string(.AppBackground.auraLimit))); return }
        var copy = theme
        copy.id = UUID().uuidString
        if copy.name.isEmpty { copy.name = theme.title }
        update { $0.themes.append(copy); $0.style = .aura; $0.aura.select(copy.id) }
    }

    func deleteTheme(_ id: String) {
        update {
            $0.themes.removeAll { $0.id == id }
            $0.aura.favorites.removeAll { $0 == id }
            if $0.aura.themeID == id { $0.aura.select("amber") }
            if $0.aura.dayThemeID == id { $0.aura.dayThemeID = "amber" }
            if $0.aura.nightThemeID == id { $0.aura.nightThemeID = "ink" }
        }
    }

    func toggleThemeFavorite(_ id: String) {
        update {
            if $0.aura.favorites.contains(id) { $0.aura.favorites.removeAll { $0 == id } }
            else { $0.aura.favorites.append(id) }
        }
    }

    func importTheme(_ url: URL) {
        do { addTheme(try AuraThemeFiles.readTheme(url)) } catch { showImportError(error) }
    }

    func extractPalette(_ url: URL, paletteDark: Bool, appearanceDark: Bool) {
        guard isLoaded, !isBusy else { return }
        work?.cancel()
        let previous = work
        isBusy = true
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let colors = try await Task.detached(priority: .userInitiated) { try AuraThemeFiles.palette(url, dark: paletteDark) }.value
                isBusy = false
                editTheme(dark: appearanceDark) { if paletteDark { $0.dark = colors } else { $0.light = colors } }
            } catch { isBusy = false; showImportError(error) }
        }
    }

    func reset() {
        update {
            // 重置当前背景与规则，不删除用户单独保存的主题作品。
            let themes = $0.themes, favorites = $0.aura.favorites
            $0 = AppBackgroundSettings()
            $0.themes = themes; $0.aura.favorites = favorites
        }
    }

    func useVideo(_ url: URL) { useMedia(url, video: true) }
    func useImage(_ url: URL) { useMedia(url, video: false) }

    /// 跨功能调用必须获得确定结果；忙碌或未加载不能静默成功。
    func applyMedia(_ url: URL, video: Bool) async throws {
        try Task.checkCancellation()
        guard isLoaded, !isBusy else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.libraryAssetLibrary))
        }
        useMedia(url, video: video)
        await finishPendingChanges()
        if case .failed(let message) = persistenceState { throw AppBackgroundError.message(message) }
    }

    private func useMedia(_ url: URL, video: Bool) {
        guard isLoaded, !isBusy else { return }
        work?.cancel()
        let previous = work
        var candidate = settings
        candidate.restoreMediaClarity()
        let token = UUID(); revision = token
        isBusy = true; persistenceState = .pending
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if revision == token { isBusy = false; work = nil } }
            do {
                let snapshot = try await (video ? store.importVideo(url, settings: candidate) : store.importImage(url, settings: candidate))
                guard revision == token else { return }
                accept(snapshot)
                failedImageURL = nil
                persistenceState = .saved(Date())
            } catch {
                failedImageURL = url
                persistenceState = .failed(error.localizedDescription)
            }
        }
    }

    func retrySave() {
        guard !isBusy else { return }
        if let failedImageURL { useMedia(failedImageURL, video: ["mp4", "mov", "m4v"].contains(failedImageURL.pathExtension.lowercased())) }
        else if isLoaded { save(immediately: true) }
        else { reload() }
    }

    func discardChanges() {
        guard !isBusy else { return }
        work?.cancel()
        // 等待在途提交再读取事实源，不能把过期内存快照当作撤销后的持久状态。
        reload()
    }

    func showImportError(_ error: Error) { persistenceState = .failed(error.localizedDescription) }

    /// 正常退出等待最后一次去抖保存或图片导入收尾，关闭管理窗口则不取消保存。
    func finishPendingChanges() async {
        while let pending = work { await pending.value }
    }

    private func accept(_ snapshot: AppBackgroundStore.Snapshot) {
        settings = snapshot.settings
        committed = snapshot.settings
        image = snapshot.imageData.flatMap(NSImage.init(data:))
        imageError = snapshot.imageError
        videoURL = snapshot.videoURL
        failedImageURL = nil
    }

    private func save(immediately: Bool = false) {
        work?.cancel()
        let candidate = settings
        let token = UUID(); revision = token
        persistenceState = .pending
        work = Task { [weak self] in
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(250)) }
                try Task.checkCancellation()
                guard let self else { return }
                try await store.save(candidate)
                guard revision == token else { return }
                committed = candidate
                if candidate.imageID == nil { image = nil; imageError = nil }
                if candidate.videoFilename == nil { videoURL = nil }
                persistenceState = .saved(Date())
                work = nil
            } catch is CancellationError { }
            catch {
                guard let self, revision == token else { return }
                persistenceState = .failed(error.localizedDescription)
                work = nil
            }
        }
    }
}
