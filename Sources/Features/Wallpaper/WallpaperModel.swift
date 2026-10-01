import ArcKitPlatform
import AppKit
import Combine
import Foundation

@MainActor
public final class WallpaperModel: ObservableObject {
    @Published private(set) var catalog = WallpaperCatalog()
    @Published private(set) var displays: [WallpaperDisplay] = []
    @Published private(set) var appliedDisplayIDs: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var operationProgress: String?
    @Published private(set) var canCancelOperation = true
    @Published private(set) var isLoaded = false
    @Published private(set) var feedback: WallpaperFeedback?
    @Published private(set) var operationID: UUID?
    var hasError: Bool { feedback?.kind == .failure }
    @Published var selectedID: UUID?
    @Published private(set) var videoPaused = false
    let library: WallpaperLibrary
    let browsing = WallpaperBrowsing()
    let channels: WallpaperChannels
    let isPreview: Bool
    private let desktop: any WallpaperDesktopHandling
    private var work: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var running = false
    private var activeDownload: UUID?
    private var pendingVideoRestores: Set<String> = []
    private var pauseReasons: Set<Int> = []
    private var sleeping: Bool { !pauseReasons.isEmpty }
    private let thumbnails = NSCache<NSURL, NSImage>()

    init(isPreview: Bool = false, desktop: (any WallpaperDesktopHandling)? = nil, library: WallpaperLibrary) {
        self.library = library
        channels = WallpaperChannels(database: library.database)
        self.isPreview = isPreview
        self.desktop = desktop ?? WallpaperDesktop(isPreview: isPreview)
        thumbnails.countLimit = 80
        if let native = self.desktop as? WallpaperDesktop {
            native.playbackFailed = { [weak self] message in
                self?.refreshDesktopStatus()
                self?.report(L10n.string(.WallpaperPlayback.libraryLiveWallpaperPlaybackFailed(String(describing: message))), kind: .failure)
            }
        }
    }

    var selected: WallpaperItem? { catalog.items.first { $0.id == selectedID } }
    var hasDynamicWallpaper: Bool { catalog.assignments.values.contains { assignment in catalog.items.contains { $0.id == assignment.itemID && $0.kind == .video } } }

    func start() {
        guard !running else { return }
        running = true
        pauseReasons.removeAll()
        refreshDisplays()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshDisplays() } }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshDisplays() } }.store(in: &observers)
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs = [(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                     (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                     (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)]
        for (reason, pair) in pairs.enumerated() {
            for (name, paused) in [(pair.0, true), (pair.1, false)] {
                workspace.publisher(for: name).sink { [weak self] _ in
                    Task { @MainActor in self?.setSleeping(paused, reason: reason) }
                }.store(in: &observers)
            }
        }
        if let previousWork = work {
            // 退出失败后可重新启动；必须先等上一项已取消的事务收尾。
            Task { [weak self] in
                await previousWork.value
                guard let self, self.running else { return }
                self.reload()
            }
        } else {
            reload()
        }
    }

    func finishPendingChanges() async { await work?.value }

    func stop() {
        running = false
        work?.cancel(); rotation?.cancel(); browsing.stop()
        observers.removeAll()
        desktop.stopVideos()
        pendingVideoRestores.removeAll()
        appliedDisplayIDs.removeAll()
    }

    func reload() {
        perform { [self] in
            await channels.load(force: true)
            catalog = try await library.load()
            thumbnails.removeAllObjects()
            thumbnailRequests.removeAll()
            isLoaded = true
            if selected == nil { selectedID = catalog.items.first?.id }
            scheduleRotation()
            pendingVideoRestores.removeAll()
            if !isPreview { try await restoreVideos(on: Set(displays.map(\.id))) }
            refreshDesktopStatus()
        }
    }

    func refreshDisplays() {
        let previous = Set(displays.map(\.id))
        displays = desktop.displays
        desktop.discardDisconnectedDisplays()
        pendingVideoRestores.formUnion(Set(displays.map(\.id)).subtracting(previous))
        refreshDesktopStatus()
        restorePendingVideosIfIdle()
    }

    func displayTitle(_ display: WallpaperDisplay) -> String {
        let number = (displays.firstIndex(where: { $0.id == display.id }) ?? 0) + 1
        return "\(number) · \(display.name)\(display.isPrimary ? L10n.string(.WallpaperPlayback.libraryMainDisplay) : "")"
    }

    func assignedItem(on displayID: String) -> WallpaperItem? {
        guard let assignment = catalog.assignments[displayID] else { return nil }
        return catalog.items.first { $0.id == assignment.itemID }
    }

    private func refreshDesktopStatus() {
        appliedDisplayIDs = Set(displays.compactMap { display in
            guard let item = assignedItem(on: display.id), desktop.isShowing(item, url: library.mediaURL(item), on: display.id) else { return nil }
            return display.id
        })
    }

    private func restorePendingVideosIfIdle() {
        guard running, isLoaded, !isPreview, !isBusy else { return }
        let targets = pendingVideoRestores.intersection(Set(displays.map(\.id))).filter { assignedItem(on: $0)?.kind == .video }
        pendingVideoRestores.removeAll()
        guard !targets.isEmpty else { return }
        perform { [self] in try await restoreVideos(on: targets) }
    }

    private func restoreVideos(on displayIDs: Set<String>) async throws {
        var failures: [String] = []
        defer { desktop.pauseVideos(videoPaused || sleeping) }
        for (id, assignment) in catalog.assignments {
            guard running, displayIDs.contains(id), displays.contains(where: { $0.id == id }),
                  let item = catalog.items.first(where: { $0.id == assignment.itemID && $0.kind == .video }) else { continue }
            if desktop.isShowing(item, url: library.mediaURL(item), on: id) { continue }
            try Task.checkCancellation()
            do {
                let change = try await desktop.apply(item, url: library.mediaURL(item),
                    request: WallpaperDesktopRequest(displayIDs: [id], scaling: assignment.scaling))
                change.commit()
                if !running { desktop.stopVideos(); return }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(item.name)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw WallpaperError.message(failures.joined(separator: "；")) }
    }

    func importFiles(_ urls: [URL]) {
        perform { [self] in try await acceptImport(try await library.importFiles(urls, into: catalog)) }
    }

    private func acceptImport(_ result: WallpaperLibrary.ImportResult) async throws {
        catalog = result.catalog
        if let id = result.itemID { selectedID = id }
        let summary = L10n.string(.Wallpaper.libraryImportedDuplicateFilesSkipped(String(describing: result.imported), String(describing: result.duplicates))) + (result.repaired > 0 ? L10n.string(.Wallpaper.libraryMissingCopiesRepaired(String(describing: result.repaired))) : "")
        report(result.failures.isEmpty ? summary : summary + "；" + result.failures.prefix(4).joined(separator: "；"), kind: result.failures.isEmpty ? .success : .failure)
    }

    func downloadedItem(_ asset: WallpaperRemoteAsset) -> WallpaperItem? {
        catalog.items.first { $0.kind == asset.kind && $0.origin?.imageURL == asset.url && FileManager.default.isReadableFile(atPath: library.mediaURL($0).path) }
    }

    @discardableResult
    func download(_ asset: WallpaperRemoteAsset, to destination: WallpaperDestination) -> UUID? {
        perform { [self] in
            if case let .desktop(request) = destination { try request.validate(connected: Set(desktop.displays.map(\.id))) }
            let imported: WallpaperItem
            if let existing = downloadedItem(asset) { imported = existing }
            else {
                let downloadID = UUID(); activeDownload = downloadID
                defer { activeDownload = nil }
                operationProgress = L10n.string(.WallpaperMedia.libraryConnectingSource)
                let file = try await WallpaperMediaDownload.download(asset.url, title: asset.title, kind: asset.kind) { [weak self] received, total in
                    Task { @MainActor in
                        guard let self, self.activeDownload == downloadID else { return }
                        let amount = L10n.fileSize(received)
                        self.operationProgress = total > 0 ? L10n.string(.WallpaperMedia.libraryDownloading(String(describing: min(100, Int(Double(received) / Double(total) * 100))), String(describing: amount))) : L10n.string(.WallpaperMedia.libraryDownloaded(String(describing: amount)))
                    }
                }
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                activeDownload = nil
                operationProgress = L10n.string(.WallpaperMedia.libraryVerifyingAssetGeneratingThumbnail)
                let result = try await library.importFiles([file], into: catalog, origin: asset.origin)
                try await acceptImport(result)
                guard let id = result.itemID, let saved = catalog.items.first(where: { $0.id == id }) else {
                    throw WallpaperError.message(result.failures.isEmpty ? L10n.string(.Wallpaper.libraryUnavailableAddAsset) : result.failures.joined(separator: "；"))
                }
                imported = saved
            }
            selectedID = imported.id
            try Task.checkCancellation()
            switch destination {
            case .library: report(L10n.string(.Wallpaper.libraryMyWallpapersAvailableOffline(String(describing: imported.name))))
            case let .desktop(request): try await applyItem(imported, request: request)
            case let .background(background): try await applyBackground(imported, action: background)
            }
        }
    }

    func useBackground(_ item: WallpaperItem, action: WallpaperBackgroundAction) {
        perform { [self] in try await applyBackground(item, action: action) }
    }
    private func applyBackground(_ item: WallpaperItem, action: WallpaperBackgroundAction) async throws {
        try Task.checkCancellation()
        operationProgress = L10n.string(.AppBackground.backgroundSavingAppBackground)
        canCancelOperation = false
        // await 的成功回执必须来自目标存储事务，不能把发起导入当作保存完成。
        try await action.apply(library.mediaURL(item), item.kind)
        report(L10n.string(.AppBackground.libraryNowArcKitBackground(String(describing: item.name))))
    }

    func createLoop(_ item: WallpaperItem, start: Double, end: Double, speed: Double) {
        perform { [self] in
            operationProgress = L10n.string(.WallpaperMedia.libraryExportingLoopSegment)
            let file = try await WallpaperVideoEditing.export(url: library.mediaURL(item), start: start, end: end, speed: speed, title: item.name)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            var origin = item.origin
            // 编辑结果已是独立作品，不能被在线原始 URL 去重复用为未编辑视频。
            origin?.imageURL = nil
            try await acceptImport(try await library.importFiles([file], into: catalog, origin: origin))
        }
    }

    func importLink(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            report(L10n.string(.Wallpaper.libraryInvalidImageUrl), kind: .failure); return
        }
        let origin = WallpaperOrigin(provider: url.host ?? L10n.string(.Wallpaper.importDirectImageTitle), pageURL: url, imageURL: url)
        download(WallpaperRemoteAsset(title: url.deletingPathExtension().lastPathComponent, url: url, kind: .image, origin: origin), to: .library)
    }

    @discardableResult
    func apply(_ item: WallpaperItem, request: WallpaperDesktopRequest) -> UUID? {
        perform { [self] in try await applyItem(item, request: request) }
    }

    private func applyItem(_ item: WallpaperItem, request: WallpaperDesktopRequest) async throws {
        // 恢复旧视频会重新显示窗口；无论成功、取消或恢复失败，都还原暂停/退出语义。
        defer {
            desktop.pauseVideos(videoPaused || sleeping)
            if !running { desktop.stopVideos() }
        }
        try Task.checkCancellation()
        guard catalog.items.contains(where: { $0.id == item.id }) else { throw WallpaperError.message(L10n.string(.Wallpaper.libraryWallpaperLongerMissing)) }
        try request.validate(connected: Set(desktop.displays.map(\.id)))
        let change = try await desktop.apply(item, url: library.mediaURL(item),
            request: request)
        var next = catalog
        for id in change.displayIDs { next.assignments[id] = WallpaperAssignment(itemID: item.id, scaling: request.scaling) }
        do {
            catalog = try await library.save(next)
            change.commit()
            selectedID = item.id
            let names = displays.filter { request.displayIDs.contains($0.id) }.map(displayTitle).joined(separator: "、")
            if change.unconfirmedDisplayIDs.isEmpty {
                report(L10n.string(.WallpaperPlayback.applySucceeded(String(describing: item.name), String(describing: names), String(describing: item.kind == .video ? L10n.string(.WallpaperMedia.libraryLiveWallpaper) : L10n.string(.Common.wallpaper)))))
            } else {
                let pending = displays.filter { change.unconfirmedDisplayIDs.contains($0.id) }.map(displayTitle).joined(separator: "、")
                report(L10n.string(.WallpaperPlayback.applySystemUnconfirmed(String(describing: pending))), kind: .notice)
            }
        } catch {
            do { try await change.rollback() }
            catch let recoveryError {
                throw WallpaperError.message(L10n.string(.WallpaperPlayback.librarySaveFailed(String(describing: error.localizedDescription), String(describing: recoveryError.localizedDescription))))
            }
            throw WallpaperError.message(L10n.string(.WallpaperPlayback.libraryRollbackFailed(String(describing: error.localizedDescription))))
        }
    }

    func updatePreferences(_ preferences: WallpaperPreferences) {
        perform { [self] in
            var next = catalog; next.preferences = preferences
            catalog = try await library.save(next)
            scheduleRotation()
        }
    }

    func toggleFavorite(_ item: WallpaperItem) {
        perform { [self] in
            var next = catalog
            guard let index = next.items.firstIndex(where: { $0.id == item.id }) else { return }
            next.items[index].isFavorite.toggle()
            catalog = try await library.save(next)
        }
    }

    func remove(_ item: WallpaperItem) {
        perform { [self] in
            guard !catalog.assignments.values.contains(where: { $0.itemID == item.id }) else {
                throw WallpaperError.message(L10n.string(.Wallpaper.libraryWallpaperStillAssigned))
            }
            var next = catalog; next.items.removeAll { $0.id == item.id }
            catalog = try await library.save(next)
            if selectedID == item.id { selectedID = catalog.items.first?.id }
            report(L10n.string(.Wallpaper.libraryRemovedLibraryMediaCopies))
        }
    }

    func nextWallpaper() {
        perform { [self] in
            let target = catalog.preferences.displayID
            let request = WallpaperDesktopRequest(displayIDs: target == "all" ? Set(desktop.displays.map(\.id)) : [target],
                scaling: catalog.preferences.scaling)
            try request.validate(connected: Set(desktop.displays.map(\.id)))
            let active = Set(catalog.assignments.filter { request.displayIDs.contains($0.key) }.values.map(\.itemID))
            let candidates = catalog.rotationCandidates(excluding: active)
            guard let item = catalog.preferences.shuffle ? candidates.randomElement() : sequentialCandidate(candidates, current: active) else {
                throw WallpaperError.message(catalog.preferences.favoritesOnly ? L10n.string(.Wallpaper.libraryAddLeastOneWallpaperFavorites) : L10n.string(.Wallpaper.libraryImportDownloadWallpaperFirst))
            }
            try await applyItem(item, request: request)
        }
    }

    func forgetDisconnectedDisplay(_ displayID: String) {
        perform { [self] in
            guard !desktop.displays.contains(where: { $0.id == displayID }) else {
                throw WallpaperError.message(L10n.string(.WallpaperPlayback.libraryDisplayReconnectedChangeWallpaper))
            }
            var next = catalog
            next.assignments.removeValue(forKey: displayID)
            if next.preferences.displayID == displayID { next.preferences.rotationEnabled = false }
            catalog = try await library.save(next)
            scheduleRotation()
            report(L10n.string(.WallpaperPlayback.displayRemovedAssignment))
        }
    }

    private func sequentialCandidate(_ candidates: [WallpaperItem], current: Set<UUID>) -> WallpaperItem? {
        guard let index = catalog.items.lastIndex(where: { current.contains($0.id) }) else { return candidates.first }
        let ordered = Array(catalog.items.dropFirst(index + 1)) + Array(catalog.items.prefix(index + 1))
        let ids = Set(candidates.map(\.id))
        return ordered.first { ids.contains($0.id) }
    }

    private func scheduleRotation() {
        rotation?.cancel()
        guard running, !isPreview, catalog.preferences.rotationEnabled else { return }
        let seconds = catalog.preferences.interval.rawValue
        rotation = Task { [weak self] in
            // 每次尝试后都等待完整间隔；断屏或播放失败不会造成密集重试。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, self.running else { return }
                if !self.sleeping && !self.isBusy { self.nextWallpaper() }
            }
        }
    }

    func toggleVideoPause() { videoPaused.toggle(); desktop.pauseVideos(videoPaused || sleeping) }
    private func setSleeping(_ value: Bool, reason: Int) {
        guard running else { return }
        // 屏幕唤醒不能撤销会话停用或整机休眠引起的暂停。
        if value { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        desktop.pauseVideos(videoPaused || sleeping)
    }

    func stopDynamicWallpaper() {
        perform { [self] in
            let videoIDs = Set(catalog.items.filter { $0.kind == .video }.map(\.id))
            var next = catalog
            next.assignments = next.assignments.filter { !videoIDs.contains($0.value.itemID) }
            // 显式停止也停止轮换，避免下一次定时器立即重新播放。
            next.preferences.rotationEnabled = false
            catalog = try await library.save(next)
            desktop.stopVideos(); videoPaused = false; scheduleRotation()
            report(L10n.string(.WallpaperPlayback.libraryLiveWallpapersRotationStoppedOriginal))
        }
    }

    private var thumbnailRequests = Set<UUID>()
    func thumbnail(_ item: WallpaperItem) -> NSImage? {
        let url = library.thumbnailURL(item)
        if let image = thumbnails.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(contentsOf: url) else {
            if thumbnailRequests.insert(item.id).inserted {
                Task { [weak self, library] in
                    do { try await library.rebuildThumbnail(item); self?.objectWillChange.send() }
                    catch { /* 缺失媒体保留条目；下次重新加载再尝试。 */ }
                }
            }
            return nil
        }
        thumbnails.setObject(image, forKey: url as NSURL)
        return image
    }

    func cancelOperation() { if canCancelOperation { work?.cancel() } }
    func showImportError(_ error: Error) { report(error.localizedDescription, kind: .failure) }
    func clearFeedback() { feedback = nil }
    private func report(_ message: String, kind: WallpaperFeedback.Kind = .success) { feedback = WallpaperFeedback(message: message, kind: kind) }

    @discardableResult
    private func perform(_ action: @escaping @MainActor () async throws -> Void) -> UUID? {
        guard !isBusy else { return nil }
        let id = UUID(); operationID = id
        isBusy = true; operationProgress = nil; canCancelOperation = true; clearFeedback()
        work = Task { [weak self] in
            defer {
                self?.isBusy = false; self?.operationProgress = nil; self?.canCancelOperation = true; self?.work = nil
                self?.refreshDesktopStatus()
                self?.restorePendingVideosIfIdle()
            }
            do { try await action() }
            catch is CancellationError { self?.report(L10n.string(.Wallpaper.libraryOperationCancelled), kind: .cancelled) }
            catch { self?.report(error.localizedDescription, kind: .failure) }
        }
        return id
    }
}
