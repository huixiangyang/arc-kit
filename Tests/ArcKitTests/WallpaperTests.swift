@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import ArcKitFinder
import CryptoKit
import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("壁纸", .serialized)
struct WallpaperTests {
    @Test("柔光旧设置一次性迁移，保留显示参数并删除旧动效列")
    func auraMigration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root)))
        var original = try await store.load().settings
        original.style = .aura; original.opacity = 0.45; original.dimming = 0.3
        try await store.save(original)
        try store.database.write { db in
            try db.execute(sql: "ALTER TABLE background_preferences ADD COLUMN motionEnabled ANY")
            try db.execute(sql: "UPDATE background_preferences SET motionEnabled=1, _types=json_set(json_remove(_types, '$.aura'), '$.motionEnabled', 'bool')")
            try db.execute(sql: "ALTER TABLE background_preferences DROP COLUMN aura")
            try db.execute(sql: "DROP TABLE background_themes")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='background-aura-v1'")
        }
        let legacyBackup = root.appendingPathComponent("legacy-backup")
        try FileManager.default.createDirectory(at: legacyBackup, withIntermediateDirectories: true)
        let legacySnapshot = legacyBackup.appendingPathComponent("app.sqlite")
        try store.database.backup(to: legacySnapshot)
        let manifest = StorageBackupManifest(format: 1, createdAt: Date(), includesAssets: false, files: [])
        try JSONEncoder().encode(manifest).write(to: legacyBackup.appendingPathComponent("manifest.json"))
        let legacyDigest = try ArcKitAssetStore.digest(legacySnapshot)
        try store.database.close()
        let migrated = try await store.load().settings
        #expect(migrated.style == .aura && migrated.opacity == 0.45 && migrated.dimming == 0.3)
        #expect(migrated.aura.resolved(in: [], dark: false).motion == .slow)
        #expect(migrated.aura.resolved(in: [], dark: false).particles == 0.5)
        #expect(try store.database.read { try !dbColumnsContainMotion($0) })
        // 再次打开不重置用户已经保存的新主题。
        var next = migrated; next.aura.select("glacier")
        try await store.save(next)
        try store.database.close()
        #expect(try await store.load().settings == next)
        try StorageMaintenance(database: store.database).restore(legacyBackup)
        #expect(try await store.load().settings == migrated)
        #expect(try ArcKitAssetStore.digest(legacySnapshot) == legacyDigest)
    }

    @Test("个人主题配方、取色与备份可往返，坏配置和失败写入不覆盖已存主题")
    @MainActor
    func auraRecipesAndBackup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("source"))))
        var settings = try await store.load().settings
        var theme = AuraTheme.builtins[3]
        theme.id = UUID().uuidString; theme.name = "Test palette"; theme.seed = 8921
        theme.motion = .standard; theme.grain = 0.2; theme.particles = 0.1
        theme.light = try AuraThemeFiles.palette(imageFixture(in: root), dark: false)
        let data = try JSONEncoder().encode(AuraThemeDocument(theme: theme))
        #expect(try AuraThemeDocument.decode(data) == theme)
        #expect(throws: (any Error).self) { try AuraThemeDocument.decode(Data(repeating: 65, count: 65_537)) }
        var broken = theme; broken.dark[0] = 0xFFFFFFFF
        #expect(throws: (any Error).self) { try broken.validated() }
        settings.style = .aura; settings.themes = [theme]; settings.aura.select(theme.id)
        settings.aura.favorites = [theme.id]; settings.aura.automation = .schedule; settings.aura.nightThemeID = theme.id
        try await store.save(settings)
        #expect(try await store.load().settings == settings)
        let readonly = AppBackgroundStore(database: ArcKitDatabase(reading: store.database.paths))
        _ = try await readonly.load()
        var candidate = settings; candidate.aura.select("mist")
        do { try await readonly.save(candidate); Issue.record("只读保存不应成功") } catch {}
        #expect(try await store.load().settings == settings)
        let backup = try StorageMaintenance(database: store.database).backup(full: true)
        let restored = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("restored")))
        _ = try SettingsRepository(database: restored).load()
        try StorageMaintenance(database: restored).restore(backup)
        #expect(try await AppBackgroundStore(database: restored).load().settings == settings)
        var dangling = settings; dangling.themes = []
        #expect(throws: (any Error).self) { try dangling.validated() }
        let model = AppBackgroundModel(store: store)
        await model.finishPendingChanges()
        model.update { $0.aura.automation = .appearance; $0.aura.manualOverride = false; $0.aura.nightThemeID = "ink" }
        await model.finishPendingChanges()
        // 编辑深色窗口所用主题的浅色配色，不能误改日间主题。
        model.extractPalette(try imageFixture(in: root), paletteDark: false, appearanceDark: true)
        await model.finishPendingChanges()
        #expect(model.settings.aura.draft?.id == "ink")
        #expect(model.settings.aura.draft?.dark == AuraTheme.builtins.first { $0.id == "ink" }?.dark)
        #expect(model.settings.aura.manualOverride)
        model.reset()
        await model.finishPendingChanges()
        #expect(model.settings.style == .system && model.settings.themes == [theme])
        #expect(model.settings.aura.favorites == [theme.id])
        model.deleteTheme(theme.id)
        await model.finishPendingChanges()
        #expect(!model.settings.aura.favorites.contains(theme.id) && model.settings.themes.isEmpty)
        model.undoAdjustment()
        await model.finishPendingChanges()
        #expect(model.settings.themes.isEmpty && !model.hasUnsavedChanges)
    }

    @Test("柔光自动切换跨午夜且手动覆盖明确，暂停相位不前进")
    func auraScheduleAndPhase() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: hour))! }
        var aura = AuraSettings(); aura.automation = .schedule
        #expect(aura.resolvedID(at: date(7), dark: true, calendar: calendar) == "amber")
        #expect(aura.resolvedID(at: date(19), dark: false, calendar: calendar) == "ink")
        aura.dayStart = 20 * 60; aura.nightStart = 6 * 60
        #expect(aura.resolvedID(at: date(2), dark: false, calendar: calendar) == "amber")
        #expect(aura.resolvedID(at: date(6), dark: false, calendar: calendar) == "ink")
        aura.select("mist")
        #expect(aura.manualOverride && aura.resolvedID(at: date(7), dark: false, calendar: calendar) == "mist")
        aura.manualOverride = false; aura.automation = .appearance
        #expect(aura.resolvedID(at: date(7), dark: true) == "ink")
        aura.dayStart = aura.nightStart
        #expect(throws: (any Error).self) { try aura.validate(themes: []) }
        var phase = AuraPhase(); phase.advance(seconds: 0.08, rate: 1)
        let paused = phase.time
        phase.advance(seconds: 10, rate: 0)
        #expect(phase.time == paused)
        phase.advance(seconds: 0.08, rate: 0.45)
        #expect(abs(phase.time - paused - 0.036) < 0.000001)
    }

    private func dbColumnsContainMotion(_ db: Database) throws -> Bool {
        try db.columns(in: "background_preferences").contains { $0.name == "motionEnabled" }
    }

    @Test("导入拥有独立副本、按内容去重，事务失败保留旧资料库")
    func importAndFailedCommit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try imageFixture(in: root)
        let directory = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: directory)))
        let empty = try await library.load()
        let result = try await library.importFiles([source, source], into: empty)
        #expect(result.imported == 1)
        #expect(result.duplicates == 1)
        let item = try #require(result.catalog.items.first)
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: library.mediaURL(item).path))
        #expect(CGImageSourceCreateWithURL(library.thumbnailURL(item) as CFURL, nil) != nil)

        let failed = WallpaperLibrary(database: ArcKitDatabase(reading: ArcKitStoragePaths(root: directory)))
        var draft = try await failed.load()
        draft.items[0].isFavorite = true
        do { _ = try await failed.save(draft); Issue.record("失败写入不应提交") } catch {}
        #expect(try await library.load() == result.catalog)
        #expect(try await library.load() == result.catalog)
        // 收藏池为空不能偷偷扩大为全部图片。
        var favorites = result.catalog
        favorites.preferences.favoritesOnly = true
        #expect(favorites.rotationCandidates(excluding: []).isEmpty)

        // 重新导入相同内容修复丢失的独立副本，不重建条目或丢失收藏、屏幕分配。
        var saved = result.catalog
        saved.items[0].isFavorite = true
        saved.assignments[UUID().uuidString] = WallpaperAssignment(itemID: item.id, scaling: .fit)
        saved = try await library.save(saved)
        let indexURL = directory.appendingPathComponent("app.sqlite")
        let indexBeforeRepair = try Data(contentsOf: indexURL)
        let replacement = try imageFixture(in: root, name: "replacement")
        try FileManager.default.removeItem(at: library.mediaURL(item))
        let repaired = try await library.importFiles([replacement], into: saved)
        #expect(repaired.repaired == 1 && repaired.imported == 0 && repaired.duplicates == 0)
        #expect(repaired.itemID == item.id && repaired.catalog == saved)
        #expect(try Data(contentsOf: library.mediaURL(item)) == Data(contentsOf: replacement))
        #expect(try Data(contentsOf: indexURL) == indexBeforeRepair)
        #expect(try await library.load() == saved)
    }

    @Test("视频入库、循环导出和应用背景均持有可播放的独立副本")
    func videoImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 24
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 24
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 32, 24, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 180, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let library = WallpaperLibrary(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("Library"))))
        let result = try await library.importFiles([source], into: try await library.load())
        #expect(result.failures.isEmpty)
        let item = try #require(result.catalog.items.first)
        #expect(item.kind == .video)
        #expect(item.width == 32 && item.height == 24)
        #expect(CGImageSourceCreateWithURL(library.thumbnailURL(item) as CFURL, nil) != nil)
        try await verifyVideoReconnect(library: library, item: item)

        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let clip = try await WallpaperVideoEditing.export(url: source, start: 0, end: min(0.5, duration), speed: 0.5)
        defer { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
        let clipAsset = AVURLAsset(url: clip)
        #expect(try await clipAsset.load(.isPlayable))
        #expect(abs(try await clipAsset.load(.duration).seconds - 1) < 0.15)
        #expect(try await clipAsset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(throws: (any Error).self) { try WallpaperVideoEditing.validate(start: 2, end: 1, speed: 1, duration: duration) }
        #expect(throws: (any Error).self) { try WallpaperVideoEditing.validate(start: 0, end: 1, speed: .nan, duration: duration) }

        let backgroundDirectory = root.appendingPathComponent("Background")
        let store = AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: backgroundDirectory)))
        let original = try await store.load()
        let snapshot = try await store.importVideo(source, settings: original.settings)
        let owned = try #require(snapshot.videoURL)
        #expect(snapshot.settings.style == .video)
        let failing = AppBackgroundStore(database: ArcKitDatabase(reading: ArcKitStoragePaths(root: backgroundDirectory)))
        let current = try await failing.load()
        do { _ = try await failing.importVideo(source, settings: current.settings); Issue.record("失败提交不应替换背景") } catch {}
        #expect(try await store.load().settings == snapshot.settings)
        try FileManager.default.removeItem(at: source)
        #expect(try await AVURLAsset(url: owned).load(.isPlayable))
        #expect(try FileManager.default.contentsOfDirectory(atPath: backgroundDirectory.appendingPathComponent("assets/media").path).filter { $0.hasSuffix(".mov") }.count == 1)
        try await store.save(AppBackgroundSettings())
        #expect(FileManager.default.fileExists(atPath: owned.path))
        let model = await AppBackgroundModel(store: AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("ModelBackground")))))
        await model.finishPendingChanges()
        await model.useVideo(clip)
        await model.finishPendingChanges()
        #expect(await model.settings.style == .video)
        #expect(await model.videoURL != nil)
        await model.clearImage()
        await model.finishPendingChanges()
        #expect(await model.videoURL == nil)
    }

    @Test("桌面应用后持久化失败必须回滚，不能发布成功状态")
    @MainActor
    func applicationRollback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try imageFixture(in: root)
        let directory = root.appendingPathComponent("Library")
        let library = WallpaperLibrary(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: directory)))
        _ = try await library.importFiles([source], into: try await library.load())
        let failed = WallpaperLibrary(database: ArcKitDatabase(reading: ArcKitStoragePaths(root: directory)))
        let desktop = WallpaperDesktopSpy()
        let other = WallpaperDisplay(id: UUID().uuidString, name: "第二屏幕", width: 1920, height: 1080,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        desktop.displays.append(other)
        let model = WallpaperModel(desktop: desktop, library: failed)
        model.start()
        defer { model.stop() }
        try await settle(model)
        #expect(model.isLoaded)
        model.apply(try #require(model.selected), request: WallpaperDesktopRequest(displayIDs: [desktop.id, other.id], scaling: .fill))
        try await settle(model)
        #expect(desktop.applied == 1)
        #expect(desktop.rolledBack == 1)
        #expect(desktop.committed == 0)
        #expect(desktop.active.isEmpty)
        #expect(model.catalog.assignments.isEmpty)
        #expect(model.hasError)
        #expect(try await library.load().assignments.isEmpty)
    }

    @Test("多屏应用固定目标、保留其他屏幕，断屏不转移目标，轮换偏好独立")
    @MainActor
    func displayTargetIsolation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WallpaperLibrary(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("Library"))))
        let first = try imageFixture(in: root)
        let second = try imageFixture(in: root, name: "second", red: 0.8)
        var catalog = try await library.importFiles([first, second], into: library.load()).catalog
        let a = try #require(catalog.items.first)
        let b = try #require(catalog.items.last)
        #expect(a.id != b.id)
        let desktop = WallpaperDesktopSpy()
        let left = desktop.displays[0]
        let right = WallpaperDisplay(id: UUID().uuidString, name: "同名显示器", width: 2560, height: 1440,
            frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
        let third = WallpaperDisplay(id: UUID().uuidString, name: "第三屏幕", width: 1920, height: 1080,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        desktop.displays = [left, right, third]
        catalog.assignments[right.id] = WallpaperAssignment(itemID: b.id, scaling: .fit)
        catalog.assignments[third.id] = WallpaperAssignment(itemID: b.id, scaling: .stretch)
        catalog.preferences.displayID = third.id
        let remoteURL = URL(string: "https://example.org/already-downloaded.png")!
        catalog.items[0].origin = WallpaperOrigin(provider: "测试", pageURL: remoteURL, imageURL: remoteURL)
        _ = try await library.save(catalog)
        desktop.active = [right.id: b.id, third.id: b.id]
        let model = WallpaperModel(desktop: desktop, library: library)
        model.start(); defer { model.stop() }
        try await settle(model)
        model.apply(a, request: WallpaperDesktopRequest(displayIDs: [left.id], scaling: .fill))
        try await settle(model)
        #expect(model.catalog.assignments[left.id]?.itemID == a.id)
        #expect(model.catalog.assignments[right.id] == catalog.assignments[right.id])
        #expect(model.catalog.assignments[third.id] == catalog.assignments[third.id])
        #expect(model.catalog.preferences == catalog.preferences)

        let both = WallpaperDesktopRequest(displayIDs: [left.id, right.id], scaling: .fit)
        model.apply(a, request: both)
        try await settle(model)
        #expect(desktop.requests.last == both)
        #expect(model.catalog.assignments[right.id]?.scaling == .fit)
        #expect(model.catalog.assignments[third.id] == catalog.assignments[third.id])
        // 在线入口复用已下载文件，也必须带入这一次选屏，不读取轮换目标。
        let online = OnlineWallpaper(id: "existing", title: "existing", imageURL: remoteURL, thumbnailURL: remoteURL,
            width: 32, height: 24, origin: catalog.items[0].origin!)
        model.download(WallpaperRemoteAsset(online), to: .desktop(WallpaperDesktopRequest(displayIDs: [right.id], scaling: .stretch)))
        try await settle(model)
        #expect(desktop.requests.last?.displayIDs == [right.id])
        #expect(model.catalog.preferences.displayID == third.id)
        let background = AppBackgroundModel(store: AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("Background")))))
        await background.finishPendingChanges()
        let priorOperation = model.operationID
        let backgroundOperation = model.download(WallpaperRemoteAsset(online), to: .background(WallpaperBackgroundIntegration.action(for: background)))
        #expect(backgroundOperation != nil && backgroundOperation != priorOperation)
        try await settle(model)
        #expect(model.operationID == backgroundOperation && model.feedback?.kind == .success)
        #expect(background.settings.style == .image && background.image != nil)
        #expect(model.catalog.items.count == 2 && desktop.requests.last?.displayIDs == [right.id])
        // 系统已接受但回读未确认时，保存意图且明确反馈，不声称正在使用，也不回滚。
        desktop.unconfirmed = [right.id]
        model.apply(b, request: WallpaperDesktopRequest(displayIDs: [right.id], scaling: .fill))
        try await settle(model)
        #expect(!model.hasError && model.feedback?.kind == .notice && model.feedback?.message == L10n.string(.WallpaperPlayback.applySystemUnconfirmed(model.displayTitle(right))))
        #expect(model.catalog.assignments[right.id]?.itemID == b.id)
        #expect(!model.appliedDisplayIDs.contains(right.id) && desktop.rolledBack == 0)
        desktop.unconfirmed = []
        let beforeDisconnect = model.catalog
        let count = desktop.applied
        desktop.displays = [left, third]
        model.refreshDisplays()
        model.apply(a, request: both)
        try await settle(model)
        #expect(model.hasError && desktop.applied == count)
        #expect(model.catalog == beforeDisconnect)
        model.apply(a, request: WallpaperDesktopRequest(displayIDs: [], scaling: .fill))
        try await settle(model)
        #expect(model.hasError && desktop.applied == count)
        // 按保留的单屏范围执行轮换，绝不扩大到其余屏幕。
        model.nextWallpaper()
        try await settle(model)
        #expect(desktop.requests.last?.displayIDs == [third.id])
        #expect(model.catalog.assignments[left.id] == beforeDisconnect.assignments[left.id])
        #expect(model.catalog.assignments[right.id] == beforeDisconnect.assignments[right.id])
        #expect(try await library.load() == model.catalog)
    }

    @Test("公开来源保留出处并容忍 Commons 混合类型元数据")
    func sourceContracts() throws {
        let data = Data(#"{"query":{"pages":[{"pageid":42,"title":"File:Landscape.jpg","index":1,"imageinfo":[{"url":"https://upload.wikimedia.org/image.jpg","thumburl":"https://upload.wikimedia.org/thumb.jpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Landscape.jpg","width":3840,"height":2160,"mime":"image/jpeg","extmetadata":{"CommonsMetadataExtension":{"value":1.2},"Artist":{"value":"<b>Ada</b>"},"LicenseShortName":{"value":"CC BY 4.0"}}}]}]}}"#.utf8)
        let page = try WallpaperOnlineSource.decode(data, provider: .commons)
        #expect(page.items.count == 1)
        #expect(page.items[0].origin.author == "Ada")
        #expect(page.items[0].origin.license == "CC BY 4.0")
        #expect(page.items[0].origin.pageURL.host == "commons.wikimedia.org")
        let wallhaven = Data(#"{"data":[{"id":"abc","url":"https://wallhaven.cc/w/abc","path":"https://w.wallhaven.cc/abc.jpg","purity":"nsfw","dimension_x":1920,"dimension_y":1080,"thumbs":{"large":"https://th.wallhaven.cc/abc.jpg"}}],"meta":{"current_page":1,"last_page":1}}"#.utf8)
        #expect(try WallpaperOnlineSource.decode(wallhaven, provider: .wallhaven).items.isEmpty)
    }

    @Test("应用背景独立持有图片，替换失败保留原背景，缺失媒体不覆盖引用")
    func applicationBackgroundPersistence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try imageFixture(in: root)
        let directory = root.appendingPathComponent("Background")
        let store = AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: directory)))
        var settings = try await store.load().settings
        settings.opacity = 0.65; settings.blur = 9; settings.dimming = 0.3
        let imported = try await store.importImage(source, settings: settings)
        let id = try #require(imported.settings.imageID)
        try FileManager.default.removeItem(at: source)
        #expect(try await store.load().settings == imported.settings)
        #expect(FileManager.default.fileExists(atPath: try await store.imageURL(id).path))
        #expect(CGImageSourceCreateWithData(try #require(imported.imageData) as CFData, nil) != nil)

        let failing = AppBackgroundStore(database: ArcKitDatabase(reading: ArcKitStoragePaths(root: directory)))
        let original = try await failing.load()
        let replacement = try imageFixture(in: root)
        do {
            _ = try await failing.importImage(replacement, settings: original.settings)
            Issue.record("替换背景保存失败不应提交")
        } catch {}
        #expect(try await store.load().settings == original.settings)
        #expect(FileManager.default.fileExists(atPath: try await store.imageURL(id).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("assets/media").path).filter { $0.hasSuffix(".jpg") }.count == 1)
        #expect(try await store.load().settings == original.settings)
        try FileManager.default.removeItem(at: try await store.imageURL(id))
        let missing = try await store.load()
        #expect(missing.imageError != nil && missing.imageData == nil)
        #expect(missing.settings.imageID == id)
    }

    @Test("壁纸交付外观等待存储回执，失败不能报告成功")
    @MainActor
    func wallpaperBackgroundDelivery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("data")))
        let library = WallpaperLibrary(database: database)
        let wallpaper = WallpaperModel(isPreview: true, library: library)
        wallpaper.importFiles([try imageFixture(in: root)])
        await wallpaper.finishPendingChanges()
        let item = try #require(wallpaper.catalog.items.first)
        let background = AppBackgroundModel(store: AppBackgroundStore(database: database))
        await background.finishPendingChanges()
        wallpaper.useBackground(item, action: WallpaperBackgroundIntegration.action(for: background))
        await wallpaper.finishPendingChanges()
        #expect(wallpaper.feedback?.kind == .success)
        #expect(try await AppBackgroundStore(database: database).load().settings.imageID == background.settings.imageID)
        #expect(background.settings.imageID != nil)
        // 相同素材交给只读存储，必须保留原来的背景并沿壁纸回执返回失败。
        let readonly = ArcKitDatabase(reading: database.paths)
        let failing = AppBackgroundModel(store: AppBackgroundStore(database: readonly))
        await failing.finishPendingChanges()
        let original = failing.settings
        wallpaper.useBackground(item, action: WallpaperBackgroundIntegration.action(for: failing))
        await wallpaper.finishPendingChanges()
        #expect(wallpaper.feedback?.kind == .failure)
        #expect(failing.settings == original)
        try readonly.close()
        try database.close()
    }

    @Test("应用背景连续预览只保存最终值，退出等待保存完成")
    @MainActor
    func applicationBackgroundEdits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppBackgroundStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root)))
        let model = AppBackgroundModel(store: store)
        await model.finishPendingChanges()
        #expect(model.isLoaded)
        for value in [0.2, 0.4, 0.7] {
            model.update { $0.style = .aura; $0.opacity = value }
        }
        await model.finishPendingChanges()
        #expect(!model.hasUnsavedChanges)
        #expect(try await store.load().settings.opacity == 0.7)
        // 用户从旧的朦胧设置选择一张新图时，应得到可辨认的画面，失败则保留原来的背景与参数。
        model.update { $0.opacity = 0.3; $0.blur = 20; $0.dimming = 0.2 }
        await model.finishPendingChanges()
        model.useImage(try imageFixture(in: root))
        await model.finishPendingChanges()
        #expect(model.settings.style == .image && model.settings.blur == 0 && model.settings.opacity == 0.75)
        #expect(try await store.load().settings == model.settings)
        model.update { $0.blur = 12 }
        await model.finishPendingChanges()
        let beforeFailure = model.settings
        model.useImage(root.appendingPathComponent("missing.png"))
        await model.finishPendingChanges()
        #expect(model.settings == beforeFailure)
        #expect(try await store.load().settings == beforeFailure)
        model.update { $0.restoreMediaClarity() }
        await model.finishPendingChanges()
        #expect(model.settings.imageID == beforeFailure.imageID && model.settings.blur == 0)
        var invalid = model.settings; invalid.blur = .nan
        #expect(throws: (any Error).self) { try invalid.validated() }
        model.reset()
        await model.finishPendingChanges()
        #expect(try await store.load().settings == AppBackgroundSettings())
    }

    @Test("动态来源只解析公开字段，订阅拒绝不安全地址，持久化可重载")
    func motionSourceContracts() async throws {
        #expect(WallpaperQuality.dimensions(width: 3840, height: 2160) == .k4)
        #expect(WallpaperQuality.dimensions(width: 2160, height: 3840) == .k4)
        #expect(WallpaperQuality.dimensions(width: 5120, height: 1440) == .k2)
        #expect(WallpaperQuality.dimensions(width: 3840, height: 1080) == .p1080)
        #expect(WallpaperQuality.dimensions(width: 0, height: 2160) == nil)
        #expect(WallpaperQuality.declared("4K 3840 × 2160") == .k4)
        #expect(WallpaperQuality.declared("preview") == nil)
        let downloadURL = URL(string: "https://example.org/wallpaper.png")!
        let png = try #require(HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]))
        #expect(try WallpaperMediaDownload.fileExtension(png, kind: .image) == "png")
        #expect(throws: (any Error).self) { try WallpaperMediaDownload.fileExtension(png, kind: .video) }
        let attachment = try #require(HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=sample.mp4"]))
        #expect(try WallpaperMediaDownload.fileExtension(attachment, kind: .video) == "mp4")
        #expect(throws: (any Error).self) { try WallpaperMediaDownload.fileExtension(attachment, kind: .image) }
        let htmlResponse = try #require(HTTPURLResponse(url: downloadURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]))
        #expect(throws: (any Error).self) { try WallpaperMediaDownload.fileExtension(htmlResponse, kind: .image) }
        let urls = try MotionWallpaperSource.decodeNASAAssets(Data(#"["http://images-assets.nasa.gov/video/a~orig.mp4","http://images-assets.nasa.gov/video/a~medium.mp4","http://elsewhere.test/a.mp4","https://images-assets.nasa.gov/video/a.jpg"]"#.utf8))
        #expect(urls.count == 2 && urls[0].scheme == "https" && urls[0].lastPathComponent == "a~medium.mp4")
        let base = URL(string: "https://motionbgs.com/")!
        let html = #"<a title="Waves live wallpaper" href=/waves><img src=/waves.jpg width=364 height=205><span class=frm>4K</span></a><a title="Waves live wallpaper" href=/waves><img src=/waves.jpg></a><a title="Bad live wallpaper" href=https://elsewhere.test/a><img src=/a.jpg></a>"#
        let items = MotionWallpaperSource.decodeMotionList(html, base: base)
        #expect(items.count == 1 && items[0].title == "Waves" && items[0].quality == .k4)
        let detail = #"<meta property=og:title content="Black Waves"><meta content=/bad-relative.mp4 property=og:video><meta property=og:image content=https://motionbgs.com/waves.jpg><a href=/dl/hd/42><b>HD</b> Wallpaper 1920x1080 mp4 file</a>"#
        let resolved = try MotionWallpaperSource.decodeMotionDetail(detail, page: base.appendingPathComponent("waves"))
        #expect(resolved.variants.count == 1 && resolved.quality == .p1080)
        #expect(resolved.variants[0].url.absoluteString == "https://motionbgs.com/dl/hd/42")
        #expect(resolved.preview == nil)
        let document = #"{"version":1,"name":"测试目录","items":[{"id":"ocean","title":"Ocean","pageURL":"https://example.org/ocean","license":"CC0","variants":[{"title":"HD","url":"https://example.org/ocean.mp4"}]}]}"#
        let feedURL = URL(string: "https://example.org/feed.json")!
        let feed = try MotionWallpaperSource.decodeFeed(Data(document.utf8), source: feedURL)
        #expect(feed.items.count == 1 && feed.items[0].origin.license == "CC0" && feed.items[0].quality == .hd)
        #expect(throws: (any Error).self) {
            try MotionWallpaperSource.decodeFeed(Data(document.replacingOccurrences(of: "https://example.org/ocean.mp4", with: "file:///etc/passwd").utf8), source: feedURL)
        }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WallpaperChannelStore(database: ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root)))
        let saved = WallpaperFeed(name: feed.name, url: feedURL)
        try await store.save(WallpaperSourceConfiguration(feeds: [saved]))
        #expect(try await store.load().feeds == [saved])
        try await store.save(WallpaperSourceConfiguration())
        #expect(try await store.load().feeds.isEmpty)
    }

    @Test("静态壁纸接受延迟回读，恢复只处理已尝试屏幕且不写失效原文件")
    @MainActor
    func imageWriteConfirmation() async throws {
        let lag = ImageDesktopFixture()
        lag.readbackAfterWaits = 3 // 模拟 700ms 后系统才返回新路径，超过旧实现的 250ms。
        let late = lag.transaction()
        #expect(try await late.apply(lag.newURL, options: [:]).isEmpty)
        #expect(lag.waits == 3 && lag.writes.count == 3)
        #expect(lag.writes.allSatisfy { $0.1 == lag.newURL })

        let stale = ImageDesktopFixture()
        stale.readbackAfterWaits = .max
        let pending = try await stale.transaction().apply(stale.newURL, options: [:])
        #expect(pending == Set(stale.targets.map(\.id)))
        #expect(stale.waits == 5 && stale.writes.count == 3) // 只返回待确认，不触发恢复写入。

        let failed = ImageDesktopFixture()
        failed.rejectedID = "right"
        let partial = failed.transaction()
        do { _ = try await partial.apply(failed.newURL, options: [:]); Issue.record("应报告系统写入失败") }
        catch { #expect(error.localizedDescription.contains("27G2G4")) }
        do { try await partial.rollback(); Issue.record("不可恢复的原文件必须报告具体原因") }
        catch { #expect(error.localizedDescription.contains(L10n.string(.WallpaperPlayback.applyOriginalUnavailable("27G2G4")))) }
        #expect(failed.writes.map(\.0) == ["left", "right", "left"])
        #expect(failed.reported["left"] == failed.original["left"])
        #expect(!failed.writes.contains { $0.1 == failed.original["right"] })
        #expect(!failed.writes.contains { $0.0 == "third" })

        let cancelled = ImageDesktopFixture()
        cancelled.missingOriginal = false
        let completed = cancelled.transaction()
        #expect(try await completed.apply(cancelled.newURL, options: [:]).isEmpty)
        cancelled.readbackAfterWaits = 2
        try await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await completed.rollback()
        }.value
        #expect(cancelled.waits == 2 && cancelled.reported == cancelled.original)

        let disconnected = ImageDesktopFixture()
        disconnected.readbackAfterWaits = .max
        disconnected.disconnectWhileWaiting = true
        let interrupted = disconnected.transaction()
        do { _ = try await interrupted.apply(disconnected.newURL, options: [:]); Issue.record("断屏应终止确认") }
        catch { #expect(error.localizedDescription == L10n.string(.WallpaperPlayback.applyTargetsDisconnected("27G2G4"))) }
        do { try await interrupted.rollback(); Issue.record("断开目标无法确认恢复") } catch {}
        #expect(disconnected.writes.filter { $0.0 == "right" }.count == 1)
    }

    @Test("混合渠道公平排列、独立分页和重试，取消后的旧结果不回写")
    @MainActor
    func mixedChannels() async throws {
        let channels = Array(WallpaperChannel.builtins.prefix(3))
        let fixture = MixedChannelFixture(ids: channels.map(\.id))
        let browser = WallpaperMixedBrowser<ChannelFixtureItem>(fetch: { try await fixture.fetch($0, query: $1, page: $2) })
        browser.search(channels: channels, query: "")
        try await settleBrowser(browser)
        #expect(browser.items.map(\.id) == ["a1", "b1", "shared", "b2"])
        #expect(browser.failures.keys.sorted() == [channels[2].id])
        browser.retry(channels[2].id)
        try await settleBrowser(browser)
        #expect(browser.items.last?.id == "c1" && browser.failures.isEmpty)
        let first = browser.items
        browser.loadMore()
        try await settleBrowser(browser)
        #expect(Array(browser.items.prefix(first.count)) == first)
        #expect(browser.items.last?.id == "b3" && browser.failures[channels[0].id] != nil)
        browser.retry(channels[0].id)
        try await settleBrowser(browser)
        #expect(browser.items.map(\.id) == ["a1", "b1", "shared", "b2", "c1", "b3", "a3"])
        #expect(!browser.hasMore && browser.failures.isEmpty)
        #expect(await fixture.count(channel: channels[0].id, query: "", page: 2) == 2)
        #expect(await fixture.count(channel: channels[2].id, query: "", page: 1) == 2)

        let settled = browser.items
        browser.activate(channels: channels)
        #expect(browser.items == settled && !browser.busy)
        #expect(await fixture.count(channel: channels[0].id, query: "", page: 1) == 1)
        browser.activate(channels: Array(channels.dropFirst()))
        #expect(browser.items.map(\.id) == ["b1", "b2", "shared", "c1", "b3"])
        #expect(!browser.busy && !browser.hasMore)
        browser.activate(channels: channels)
        try await settleBrowser(browser)
        #expect(await fixture.count(channel: channels[0].id, query: "", page: 1) == 2)
        #expect(await fixture.count(channel: channels[1].id, query: "", page: 1) == 1)
        #expect(await fixture.count(channel: channels[1].id, query: "", page: 2) == 1)
        #expect(browser.items.contains { $0.id == "b3" } && browser.hasMore)
        browser.loadMore()
        try await settleBrowser(browser)
        #expect(browser.items.last?.id == "a3" && !browser.hasMore)

        await fixture.rejectAll(true)
        let beforeRefresh = browser.items
        browser.search(channels: channels, query: "")
        #expect(browser.showingPrevious && browser.items == beforeRefresh)
        try await settleBrowser(browser)
        #expect(browser.showingPrevious && browser.items == beforeRefresh && browser.failures.count == 3)
        browser.activate(channels: Array(channels.dropFirst()))
        #expect(browser.showingPrevious && browser.failures.count == 2)
        #expect(browser.items.map(\.id) == ["b1", "b2", "shared", "c1", "b3"])
        await fixture.rejectAll(false)
        browser.retryFailures()
        try await settleBrowser(browser)
        #expect(!browser.showingPrevious && browser.failures.isEmpty && browser.items.contains { $0.id == "b1" })

        browser.search(channels: channels, query: "paused")
        for _ in 0..<100 {
            if await fixture.count(channel: channels[0].id, query: "paused", page: 1) > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        browser.stop()
        #expect(!browser.busy && browser.paused == Set(channels.map(\.id)))
        browser.loadMore()
        try await settleBrowser(browser)
        #expect(browser.paused.isEmpty && browser.items.count == 3)
        #expect(await fixture.count(channel: channels[0].id, query: "paused", page: 1) == 2)

        browser.search(channels: channels, query: "old")
        for _ in 0..<100 {
            if await fixture.count(channel: channels[0].id, query: "old", page: 1) > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        browser.search(channels: [channels[1]], query: "new")
        try await settleBrowser(browser)
        try await Task.sleep(for: .milliseconds(120)) // 替身故意忽略取消并返回旧结果。
        #expect(browser.items.map(\.id) == ["new-" + channels[1].id])
        #expect(browser.failures.isEmpty && !browser.busy)
        browser.search(channels: [], query: "")
        #expect(browser.items.isEmpty && !browser.busy && !browser.hasMore)
    }

    @Test("渠道开关和订阅可重载，读取或保存失败不伪造成功")
    @MainActor
    func channelManagement() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let feed = WallpaperFeed(name: "原有目录", url: URL(string: "https://example.org/original.json")!)
        let database = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root))
        try await WallpaperChannelStore(database: database).save(WallpaperSourceConfiguration(feeds: [feed]))
        let model = WallpaperChannels(database: database, fetchFeed: { _ in ("新目录", []) })
        await model.load()
        #expect(model.loaded && model.enabled(.image).count == 4 && model.enabled(.video).count == 3)
        for channel in WallpaperChannel.builtins where channel.kind == .image { await model.setEnabled(channel, false) }
        #expect(model.enabled(.image).isEmpty)
        try await model.subscribe("https://example.org/new.json")
        do { try await model.subscribe("https://example.org/new.json"); Issue.record("重复订阅应拒绝") } catch {}
        do { try await model.subscribe("file:///tmp/feed.json"); Issue.record("非 HTTPS 应拒绝") } catch {}
        await model.setEnabled(WallpaperChannel(source: .feed(feed)), false)
        await model.remove(feed)
        let reloaded = WallpaperChannels(database: database)
        await reloaded.load()
        #expect(reloaded.enabled(.image).isEmpty && reloaded.enabled(.video).count == 3)
        #expect(reloaded.feeds.count == 1 && reloaded.feeds.first?.name == "新目录")
        try await model.subscribe(feed.url.absoluteString)
        let readded = WallpaperChannels(database: database)
        await readded.load()
        #expect(readded.enabled(.video).count == 4 && readded.feeds.count == 2)
        try database.write { try $0.execute(sql: "CREATE TRIGGER reject_channel BEFORE INSERT ON wallpaper_source_preferences BEGIN SELECT RAISE(FAIL,'injected'); END") }
        await reloaded.setEnabled(WallpaperChannel.builtins[0], true)
        #expect(reloaded.error != nil && reloaded.enabled(.image).isEmpty)
        try database.write { try $0.execute(sql: "DROP TRIGGER reject_channel; UPDATE wallpaper_source_preferences SET disabled='broken'") }
        let broken = WallpaperChannels(database: database)
        await broken.load()
        #expect(!broken.loaded && broken.error != nil)

    }

    @MainActor
    private func settleBrowser(_ browser: WallpaperMixedBrowser<ChannelFixtureItem>) async throws {
        for _ in 0..<200 where browser.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!browser.busy)
    }

    @MainActor
    private func verifyVideoReconnect(library: WallpaperLibrary, item: WallpaperItem) async throws {
        let desktop = WallpaperDesktopSpy()
        let original = desktop.displays[0]
        var catalog = try await library.load()
        catalog.assignments[original.id] = WallpaperAssignment(itemID: item.id, scaling: .fit)
        _ = try await library.save(catalog)
        let model = WallpaperModel(desktop: desktop, library: library)
        model.start(); defer { model.stop() }
        try await settle(model)
        #expect(desktop.applied == 1 && model.appliedDisplayIDs == [original.id])
        desktop.displays = []
        model.refreshDisplays()
        #expect(model.appliedDisplayIDs.isEmpty)
        #expect(model.catalog.assignments[original.id]?.itemID == item.id)
        // 系统重连时保持同一 UUID；恢复该屏幕视频，不向新接入的其他屏幕分配。
        let added = WallpaperDisplay(id: UUID().uuidString, name: "新屏幕", width: 1920, height: 1080,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        desktop.displays = [original, added]
        model.refreshDisplays()
        try await settle(model)
        #expect(desktop.applied == 2)
        #expect(desktop.requests.last == WallpaperDesktopRequest(displayIDs: [original.id], scaling: .fit))
        #expect(model.appliedDisplayIDs == [original.id])
        #expect(model.catalog.assignments[added.id] == nil)
    }

    @Test("旧数据完整离线导入，损坏源不启用；备份跨根恢复模板和媒体")
    func storageMigration() async throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("old")
        let output = root.appendingPathComponent("new")
        let fm = FileManager.default
        for folder in ["Settings", "Wallpapers/Media", "Background", "NewFileTemplates"] {
            try fm.createDirectory(at: legacy.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func envelope<T: Encodable>(_ value: T, folder: String, domain: String, version: Int) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(value)
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let object: [String: Any] = ["schemaVersion": 1, "domain": domain, "generation": 4,
                "checksum": digest, "payload": try JSONSerialization.jsonObject(with: payload)]
            try JSONSerialization.data(withJSONObject: object).write(to: legacy.appendingPathComponent("\(folder)/\(domain).v\(version).json"))
        }
        var settings = AppSettings.defaults
        settings.appearance = .dark
        settings.finder.menuConfiguration.favoriteDirectories = [FavoriteDirectory(name: "Second", path: "/tmp/b", sortOrder: 2), FavoriteDirectory(name: "First", path: "/tmp/a", sortOrder: 1)]
        let template = legacy.appendingPathComponent("NewFileTemplates/custom.txt")
        try fm.createDirectory(at: template, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: template.appendingPathComponent("contents.txt"))
        try fm.createDirectory(at: template.appendingPathComponent("empty"), withIntermediateDirectories: true)
        settings.finder.menuConfiguration.fileTemplates.append(ConfigurableNewFileTemplate(id: "fixture", displayName: "自定义", fileExtension: "txt", sortOrder: 99, templateSource: .managedUserFile(template.path)))
        // 冻结旧 JSON 字段；当前 GlobalSettings 新增字段不能混入旧版本校验和。
        struct LegacyGlobalFixture: Encodable {
            let appearance: ArcAppearance
            let reduceMotionEnabled: Bool
            let showDockIcon: Bool
            let launchAtLoginEnabled: Bool
        }
        try envelope(LegacyGlobalFixture(appearance: settings.appearance,
            reduceMotionEnabled: settings.reduceMotionEnabled, showDockIcon: settings.showDockIcon,
            launchAtLoginEnabled: settings.launchAtLoginEnabled), folder: "Settings", domain: "global", version: 2)
        try envelope(settings.finder, folder: "Settings", domain: "finder", version: 3)
        try envelope(settings.windowManagement, folder: "Settings", domain: "window", version: 1)
        try envelope(settings.mouseEnhancement, folder: "Settings", domain: "mouse", version: 2)
        let fixture = try imageFixture(in: root)
        let item = WallpaperItem(id: UUID(), name: "原名称", fileExtension: "png", kind: .image, width: 32, height: 24,
            byteCount: Int64(try Data(contentsOf: fixture).count), digest: try ArcKitAssetStore.digest(fixture), addedAt: Date(), isFavorite: true)
        try fm.copyItem(at: fixture, to: legacy.appendingPathComponent("Wallpapers/Media/\(item.id.uuidString).png"))
        var catalog = WallpaperCatalog(); catalog.items = [item]
        catalog.assignments[UUID().uuidString] = WallpaperAssignment(itemID: item.id, scaling: .fit)
        try envelope(catalog, folder: "Wallpapers", domain: "wallpaper", version: 1)
        let backgroundID = UUID().uuidString
        try fm.copyItem(at: fixture, to: legacy.appendingPathComponent("Background/\(backgroundID).jpg"))
        struct OldBackground: Encodable {
            let style = "image"; let imageID: String; let imageName = "旧背景"
            let opacity = 0.8; let blur = 0.0; let dimming = 0.1; let motionEnabled = false
        }
        try envelope(OldBackground(imageID: backgroundID), folder: "Background", domain: "background", version: 1)
        let feeds = [WallpaperFeed(name: "Fixture", url: URL(string: "https://example.com/feed.json")!)]
        try JSONEncoder().encode(feeds).write(to: legacy.appendingPathComponent("Wallpapers/motion-feeds.json"))
        try JSONEncoder().encode(Set(["motion"])).write(to: legacy.appendingPathComponent("Wallpapers/wallpaper-channels.json"))
        try await LegacyStorageImport.run(source: legacy, destination: output)
        let database = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: output))
        let migrated = try SettingsRepository(database: database).load()
        #expect(migrated.finder.menuConfiguration.favoriteDirectories == settings.finder.menuConfiguration.favoriteDirectories)
        #expect(migrated.appearance == settings.appearance)
        #expect(try await WallpaperLibrary(database: database).load() == catalog)
        #expect(try await AppBackgroundStore(database: database).load().settings.imageID == item.digest)
        #expect(try await WallpaperChannelStore(database: database).load().feeds == feeds)
        let full = try StorageMaintenance(database: database).backup(full: true)
        let restored = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("restored")))
        _ = try SettingsRepository(database: restored).load()
        try StorageMaintenance(database: restored).restore(full)
        let restoredSettings = try SettingsRepository(database: restored).load()
        #expect(restoredSettings.finder.menuConfiguration.fileTemplates.last?.templateSource == .managedUserFile(restored.paths.templates.appendingPathComponent("custom.txt").path))
        #expect(try await WallpaperLibrary(database: restored).load() == catalog)
        #expect(try Data(contentsOf: restored.paths.templates.appendingPathComponent("custom.txt/contents.txt")) == Data("fixture".utf8))
        #expect(fm.fileExists(atPath: restored.paths.templates.appendingPathComponent("custom.txt/empty").path))
        // 丢失引用必须阻止完整备份；旧导入失败也不能留下半个新根。
        try fm.removeItem(at: database.paths.media.appendingPathComponent(item.filename))
        #expect(throws: (any Error).self) { try StorageMaintenance(database: database).backup(full: true) }
        try Data("broken".utf8).write(to: legacy.appendingPathComponent("Settings/finder.v3.json"))
        let rejected = root.appendingPathComponent("rejected")
        do { try await LegacyStorageImport.run(source: legacy, destination: rejected); Issue.record("应拒绝损坏源") } catch {}
        #expect(!fm.fileExists(atPath: rejected.path))
        #expect(fm.fileExists(atPath: template.path))
        try database.close(); try restored.close()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-WallpaperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func imageFixture(in directory: URL, name: String = "sample", red: CGFloat = 0.2) throws -> URL {
        let url = directory.appendingPathComponent("\(name).png")
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor
    private func settle(_ model: WallpaperModel) async throws {
        for _ in 0..<300 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isBusy)
    }
}

@MainActor
private final class WallpaperDesktopSpy: WallpaperDesktopHandling {
    let id = UUID().uuidString
    var requests: [WallpaperDesktopRequest] = []
    var applied: Int { requests.count }
    var rolledBack = 0
    var unconfirmed: Set<String> = []
    var committed = 0
    var active: [String: UUID] = [:]
    var videoDisplays: Set<String> = []
    var displays: [WallpaperDisplay]

    init() {
        displays = [WallpaperDisplay(id: id, name: "同名显示器", width: 1920, height: 1080,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isPrimary: true)]
    }
    func apply(_ item: WallpaperItem, url: URL, request: WallpaperDesktopRequest) async throws -> WallpaperDesktopChange {
        try request.validate(connected: Set(displays.map(\.id)))
        requests.append(request)
        let previous = active
        let previousVideos = videoDisplays
        for id in request.displayIDs {
            if !unconfirmed.contains(id) { active[id] = item.id }
            if item.kind == .video { videoDisplays.insert(id) } else { videoDisplays.remove(id) }
        }
        return WallpaperDesktopChange(displayIDs: request.displayIDs.sorted(), unconfirmedDisplayIDs: request.displayIDs.intersection(unconfirmed), commit: { self.committed += 1 }, rollback: {
            self.rolledBack += 1
            for id in request.displayIDs {
                self.active[id] = previous[id]
                if previousVideos.contains(id) { self.videoDisplays.insert(id) } else { self.videoDisplays.remove(id) }
            }
        })
    }
    func isShowing(_ item: WallpaperItem, url: URL, on displayID: String) -> Bool { active[displayID] == item.id }
    func stopVideos() { for id in videoDisplays { active.removeValue(forKey: id) }; videoDisplays.removeAll() }
    func pauseVideos(_ paused: Bool) {}
    func discardDisconnectedDisplays() {
        let connected = Set(displays.map(\.id))
        active = active.filter { connected.contains($0.key) }
        videoDisplays.formIntersection(connected)
    }
}

private struct ChannelFixtureItem: Identifiable, Equatable, Sendable { let id: String }

private actor MixedChannelFixture {
    let ids: [String]
    var calls: [String: Int] = [:]
    private var rejecting = false
    func rejectAll(_ value: Bool) { rejecting = value }
    init(ids: [String]) { self.ids = ids }
    func count(channel: String, query: String, page: Int) -> Int { calls["\(channel)|\(query)|\(page)", default: 0] }
    func fetch(_ channel: WallpaperChannel, query: String, page: Int) async throws -> WallpaperChannelPage<ChannelFixtureItem> {
        let key = "\(channel.id)|\(query)|\(page)"
        calls[key, default: 0] += 1
        if rejecting { throw WallpaperError.message("fixture refresh failed") }
        if query == "old" || query == "paused" { try? await Task.sleep(for: .milliseconds(100)) }
        if !query.isEmpty { return WallpaperChannelPage(items: [.init(id: query + "-" + channel.id)], more: false) }
        let index = ids.firstIndex(of: channel.id)!
        if calls[key] == 1 && (index == 2 || index == 0 && page == 2) { throw WallpaperError.message("fixture unavailable") }
        let values: [String]
        switch (index, page) {
        case (0, 1): values = ["a1", "shared", "a1"]
        case (1, 1): values = ["b1", "b2", "shared"]
        case (2, 1): values = ["c1"]
        case (0, 2): values = ["a1", "a3"]
        default: values = ["b1", "b3"]
        }
        return WallpaperChannelPage(items: values.map { .init(id: $0) }, more: index != 2 && page == 1)
    }
}

@MainActor
private final class ImageDesktopFixture {
    let targets = [
        WallpaperDisplay(id: "left", name: "内建屏幕", width: 1920, height: 1080),
        WallpaperDisplay(id: "right", name: "27G2G4", width: 1920, height: 1080),
        WallpaperDisplay(id: "third", name: "第三屏幕", width: 1920, height: 1080)
    ]
    let newURL = URL(fileURLWithPath: "/tmp/fixture-new.jpg")
    let original = ["left": URL(fileURLWithPath: "/tmp/fixture-original.jpg"),
                    "right": URL(fileURLWithPath: "/tmp/fixture-deleted.heic"),
                    "third": URL(fileURLWithPath: "/tmp/fixture-third.jpg")]
    var connected: Set<String> = ["left", "right", "third"]
    var reported: [String: URL] = [:]
    var actual: [String: URL] = [:]
    var writes: [(String, URL)] = []
    var waits = 0
    var readbackAfterWaits = 0
    var rejectedID: String?
    var disconnectWhileWaiting = false
    var missingOriginal = true
    init() { reported = original; actual = original }
    func transaction() -> WallpaperImageTransaction {
        WallpaperImageTransaction(targets: targets, access: WallpaperImageAccess(
            connectedIDs: { self.connected },
            read: { .init(url: self.reported[$0], options: [:]) },
            write: { id, url, _ in
                self.writes.append((id, url))
                if id == self.rejectedID && url == self.newURL { throw WallpaperError.message("系统拒绝") }
                self.actual[id] = url
                if self.readbackAfterWaits == 0 { self.reported[id] = url }
            },
            isReadable: { !self.missingOriginal || $0 != self.original["right"] }
        ), wait: { _ in
            try Task.checkCancellation()
            self.waits += 1
            if self.disconnectWhileWaiting { self.connected.remove("right") }
            if self.waits >= self.readbackAfterWaits { self.reported = self.actual }
        })
    }
}
