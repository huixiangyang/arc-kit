import ArcKitPlatform
import ArcKitPersistence
import ArcKitFinder
import ArcKitWindow
import ArcKitMouse
import AVFoundation
import CryptoKit
import Foundation
import Darwin

@_silgen_name("flock")
private func legacyStorageFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// 仅用于离线交付切换；日常配置读写不调用旧格式解析，也不双写旧目录。
public enum LegacyStorageImport {
    public static func run(source: URL, destination: URL) async throws {
        let fm = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path),
              !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/") else {
            throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportMigrationRequiresExistingLegacyFolder))
        }
        let ownerURL = source.appendingPathComponent("Runtime/host-session.json")
        if fm.fileExists(atPath: ownerURL.path), try RuntimeHostSession.load(from: ownerURL).isOwnerAlive == true {
            throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportQuitOldArcKitFirstData))
        }
        // 持有旧仓库锁直至切换完毕；正式根还须阻止仍在退出中的 Host/Worker。
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors { Darwin.close(descriptor) } }
        var locks = ["Settings", "Wallpapers", "Background"].map { source.appendingPathComponent($0 + "/.repository.lock") }
        let legacyRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc Kit").resolvingSymlinksInPath()
        if source == legacyRoot {
            locks += ["host", "worker"].map { fm.temporaryDirectory.appendingPathComponent("com.archalo.arckit." + $0 + ".lock") }
        }
        for lock in locks where fm.fileExists(atPath: lock.path) {
            let fd = Darwin.open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportLockCheckFailed)) }
            descriptors.append(fd)
            guard legacyStorageFlock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportOldAppBackgroundService)) }
        }
        // 旧文件事务未完成时停止，不能猜测哪一份文件已经提交。
        for folder in ["Settings", "Wallpapers", "Background"] {
            guard !fm.fileExists(atPath: source.appendingPathComponent(folder + "/.pending-transaction.json").path) else {
                throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportLegacyDataUnfinishedTransactionComplete))
            }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".arc-kit-import-\(UUID().uuidString)")
        let paths = ArcKitStoragePaths(root: staging)
        let database = ApplicationStorage.makeDatabase(paths: paths)
        var completed = false
        defer { if !completed { try? database.close(); try? fm.removeItem(at: staging) } }
        var settings = AppSettings.defaults
        try read(LegacyGlobalSettings.self, directory: source.appendingPathComponent("Settings"), domain: "global", version: 2, defaultValue: LegacyGlobalSettings()).apply(to: &settings)
        settings.finder = try read(FinderRuntimeSettings.self, directory: source.appendingPathComponent("Settings"), domain: "finder", version: 3, defaultValue: .defaults)
        settings.windowManagement = try read(WindowManagementSettings.self, directory: source.appendingPathComponent("Settings"), domain: "window", version: 1, defaultValue: .defaults)
        settings.mouseEnhancement = try read(MouseEnhancementSettings.self, directory: source.appendingPathComponent("Settings"), domain: "mouse", version: 2, defaultValue: .defaults)
        _ = try SettingsRepository(database: database).load()
        for index in settings.finder.menuConfiguration.fileTemplates.indices {
            guard case .managedUserFile(let path) = settings.finder.menuConfiguration.fileTemplates[index].templateSource else { continue }
            let old = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard old.path.hasPrefix(source.appendingPathComponent("NewFileTemplates").path + "/") else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportTemplateReferenceOutsideLegacy)) }
            let relative = String(old.path.dropFirst(source.appendingPathComponent("NewFileTemplates").path.count + 1))
            let output = paths.templates.appendingPathComponent(relative)
            try ArcKitStoragePaths.secureDirectory(output.deletingLastPathComponent())
            try fm.copyItem(at: old, to: output)
            try ArcKitStoragePaths.secureTree(output)
            settings.finder.menuConfiguration.fileTemplates[index].templateSource = .managedUserFile(destination.appendingPathComponent("assets/templates/" + relative).path)
        }
        let expectedSettings = settings
        try SettingsRepository(database: database).save(settings)
        let catalog = try read(WallpaperCatalog.self, directory: source.appendingPathComponent("Wallpapers"), domain: "wallpaper", version: 1, defaultValue: WallpaperCatalog())
        let assets = ArcKitAssetStore(database: database)
        let library = WallpaperLibrary(database: database)
        var validatedCatalog = try await library.load()
        for item in catalog.items {
            let old = source.appendingPathComponent("Wallpapers/Media/\(item.id.uuidString).\(item.fileExtension)")
            let imported = try await library.importFiles([old], into: validatedCatalog)
            guard imported.failures.isEmpty, let verified = imported.catalog.items.first(where: { $0.digest == item.digest }), verified.byteCount == item.byteCount,
                  verified.width == item.width, verified.height == item.height, verified.kind == item.kind else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportCatalogMismatch)) }
            validatedCatalog = imported.catalog
            let thumbnail = source.appendingPathComponent("Wallpapers/Thumbnails/\(item.id.uuidString).jpg")
            if fm.fileExists(atPath: thumbnail.path) {
                let target = paths.thumbnails.appendingPathComponent("\(item.digest).jpg")
                if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: thumbnail, to: target); try ArcKitStoragePaths.secureFile(target) }
            }
        }
        _ = try await library.save(catalog)
        let legacyBackground = try read(LegacyBackground.self, directory: source.appendingPathComponent("Background"), domain: "background", version: 1, defaultValue: LegacyBackground())
        var background = legacyBackground.settings
        if let id = legacyBackground.imageID {
            guard UUID(uuidString: id) != nil else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportInvalidLegacyBackgroundIdentifier)) }
            background.imageID = try assets.importFile(source.appendingPathComponent("Background/\(id).jpg")).digest
        }
        if let file = legacyBackground.videoFilename {
            guard !file.contains("/"), !file.contains("..") else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportInvalidLegacyVideoPath)) }
            let imported = try assets.importFile(source.appendingPathComponent("Background/" + file))
            guard try await AVURLAsset(url: imported.url).load(.isPlayable) else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportVideoUnplayable)) }
            background.videoFilename = imported.filename
        }
        let backgroundStore = AppBackgroundStore(database: database)
        _ = try await backgroundStore.load()
        try await backgroundStore.save(background)
        let feeds: [WallpaperFeed] = try plain(source.appendingPathComponent("Wallpapers/motion-feeds.json"), defaultValue: [])
        let disabled: Set<String> = try plain(source.appendingPathComponent("Wallpapers/wallpaper-channels.json"), defaultValue: [])
        let channelStore = WallpaperChannelStore(database: database)
        try await channelStore.save(WallpaperSourceConfiguration(feeds: feeds, disabled: disabled))
        guard try SettingsRepository(database: database).load() == expectedSettings,
              try await library.load() == catalog,
              try await backgroundStore.load().settings == background,
              try await backgroundStore.load().imageError == nil,
              try await channelStore.load().feeds == feeds, try await channelStore.load().disabled == disabled else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportReadbackMismatch)) }
        try database.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportMigratedDatabaseValidationFailed)) }
        }
        let report = L10n.string(.DataManagement.legacyImportPreservedData(String(describing: source.path), String(describing: catalog.items.count), String(describing: catalog.assignments.count), String(describing: feeds.count)))
        try ArcKitAtomicFile.writeAtomically(Data(report.utf8), to: paths.diagnostics.appendingPathComponent("storage-import.txt"))
        _ = try StorageMaintenance(database: database).backup(full: false)
        try database.close()
        try fm.moveItem(at: staging, to: destination)
        completed = true
    }

    private struct Envelope<T: Codable>: Codable {
        let schemaVersion: Int; let domain: String; let generation: UInt64; let checksum: String; let payload: T
    }
    private static func read<T: Codable>(_ type: T.Type, directory: URL, domain: String, version: Int, defaultValue: T) throws -> T {
        var present = false
        for suffix in [".json", ".last-known-good.json"] {
            let url = directory.appendingPathComponent("\(domain).v\(version)\(suffix)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            present = true
            do {
                let envelope = try JSONDecoder().decode(Envelope<T>.self, from: ArcKitBoundedFileReader.read(from: url, maximumBytes: 8 * 1_024 * 1_024))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let digest = SHA256.hash(data: try encoder.encode(envelope.payload)).map { String(format: "%02x", $0) }.joined()
                guard envelope.schemaVersion == 1, envelope.domain == domain, envelope.generation > 0, envelope.checksum == digest else { throw CocoaError(.fileReadCorruptFile) }
                return envelope.payload
            } catch { continue }
        }
        guard !present else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportInvalidSettings(String(describing: domain)))) }
        guard directory.lastPathComponent != "Settings" else { throw ArcKitDatabaseError.message(L10n.string(.DataManagement.legacyImportSettingsMissing(String(describing: domain)))) }
        return defaultValue
    }
    private static func plain<T: Decodable>(_ url: URL, defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        return try JSONDecoder().decode(T.self, from: ArcKitBoundedFileReader.read(from: url, maximumBytes: 1_048_576))
    }
    /// 离线导入保留旧 payload 的编码形状，先验证原 checksum，再映射到当前字段。
    private struct LegacyGlobalSettings: Codable {
        var appearance: ArcAppearance = .system
        var reduceMotionEnabled = false
        var showDockIcon = true
        var launchAtLoginEnabled = true
        var language: ArcKitLanguage?
        func apply(to settings: inout AppSettings) {
            settings.appearance = appearance
            settings.reduceMotionEnabled = reduceMotionEnabled
            settings.showDockIcon = showDockIcon
            settings.launchAtLoginEnabled = launchAtLoginEnabled
            settings.language = language ?? .system
        }
    }

    private struct LegacyBackground: Codable {
        var style: AppBackgroundStyle = .system
        var imageID: String?
        var imageName: String?
        var videoFilename: String?
        var opacity = 0.75
        var blur = 0.0
        var dimming = 0.2
        var motionEnabled = false
        var settings: AppBackgroundSettings {
            var v = AppBackgroundSettings(); v.style = style; v.imageName = imageName; v.opacity = opacity
            v.blur = blur; v.dimming = dimming; var theme = AuraTheme.amber; theme.motion = motionEnabled ? .slow : .still; theme.particles = motionEnabled ? 0.5 : 0; v.aura.draft = theme; return v
        }
    }
}
