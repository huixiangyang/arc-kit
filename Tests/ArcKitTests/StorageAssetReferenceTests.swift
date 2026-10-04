@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitPlatform
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("备份素材引用")
struct StorageAssetReferenceTests {
    enum Mismatch: CaseIterable, Sendable {
        case wallpaperPath, wallpaperBytes, backgroundImagePath, backgroundVideoIndex
    }

    @Test("拒绝素材引用错配的备份且保留当前数据，有效包仍可跨根恢复", arguments: Mismatch.allCases)
    func restoreAssetReferences(mismatch: Mismatch) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ArcKit-StorageAssetTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("source")))
        defer { try? source.close() }
        let sourceLibrary = WallpaperLibrary(database: source)
        let image = try makeImage(in: root)
        let imported = try await sourceLibrary.importFiles([image], into: sourceLibrary.load())
        let item = try #require(imported.catalog.items.first)
        let backgroundStore = AppBackgroundStore(database: source)
        let background = try await backgroundStore.importImage(image, settings: backgroundStore.load().settings)
        let backgroundID = try #require(background.settings.imageID)
        let valid = try StorageMaintenance(database: source).backup(full: true)
        let invalid = root.appendingPathComponent("invalid.arckitbackup")
        try fm.copyItem(at: valid, to: invalid)
        try corruptReferences(in: invalid, mismatch: mismatch, backgroundID: backgroundID)

        let target = ApplicationStorage.makeDatabase(paths: ArcKitStoragePaths(root: root.appendingPathComponent("target")))
        defer { try? target.close() }
        let targetLibrary = WallpaperLibrary(database: target)
        var current = try await targetLibrary.importFiles([image], into: targetLibrary.load()).catalog
        current.items[0].isFavorite = true
        current = try await targetLibrary.save(current)
        let currentBackground = try await AppBackgroundStore(database: target).load().settings
        let databaseBefore = try ArcKitAssetStore.digest(target.paths.database)
        let filesBefore = try fm.contentsOfDirectory(atPath: target.paths.media.path).sorted()
        let service = StorageMaintenance(database: target)

        #expect(throws: ArcKitDatabaseError.self) { try service.restore(invalid) }
        #expect(try ArcKitAssetStore.digest(target.paths.database) == databaseBefore)
        #expect(try await targetLibrary.load() == current)
        #expect(try await AppBackgroundStore(database: target).load().settings == currentBackground)
        #expect(try fm.contentsOfDirectory(atPath: target.paths.media.path).sorted() == filesBefore)
        #expect(try ArcKitAssetStore.digest(targetLibrary.mediaURL(current.items[0])) == item.digest)

        // 拒绝坏包后仍允许恢复真实有效包；恢复后的领域引用和实际文件一起验证。
        try service.restore(valid)
        #expect(try await targetLibrary.load() == imported.catalog)
        let restoredBackground = try await AppBackgroundStore(database: target).load()
        #expect(restoredBackground.settings == background.settings)
        #expect(restoredBackground.imageError == nil && restoredBackground.imageData != nil)
        #expect(try ArcKitAssetStore.digest(targetLibrary.mediaURL(item)) == item.digest)
    }

    private func corruptReferences(in backup: URL, mismatch: Mismatch, backgroundID: String) throws {
        let manifestURL = backup.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(StorageBackupManifest.self, from: Data(contentsOf: manifestURL))
        var entries = manifest.files
        let database = try DatabaseQueue(path: backup.appendingPathComponent("app.sqlite").path)
        defer { try? database.close() }
        try database.write { db in
            switch mismatch {
            case .wallpaperPath:
                try db.execute(sql: "UPDATE wallpaper_items SET fileExtension='jpg'")
            case .wallpaperBytes:
                try db.execute(sql: "UPDATE wallpaper_items SET byteCount=byteCount+1")
            case .backgroundImagePath:
                let index = try #require(entries.firstIndex { $0.digest == backgroundID })
                let entry = entries[index]
                let moved = "assets/media/moved.jpg"
                try FileManager.default.moveItem(at: backup.appendingPathComponent(entry.path), to: backup.appendingPathComponent(moved))
                try db.execute(sql: "UPDATE assets SET path=? WHERE digest=?", arguments: [moved, backgroundID])
                entries[index] = .init(path: moved, digest: entry.digest, bytes: entry.bytes, isDirectory: false)
            case .backgroundVideoIndex:
                // 保留清单和文件哈希一致，只伪造一个未登记的历史视频引用，隔离验证引用边界。
                let entry = try #require(entries.first { $0.digest == backgroundID })
                let filename = backgroundID + ".mov"
                let path = "assets/media/" + filename
                try FileManager.default.copyItem(at: backup.appendingPathComponent(entry.path), to: backup.appendingPathComponent(path))
                entries.append(.init(path: path, digest: entry.digest, bytes: entry.bytes, isDirectory: false))
                var settings = try #require(try ArcKitRecord.load(AppBackgroundSettings.self, layout: AppBackgroundSettings.recordLayout, db: db))
                settings.videoFilename = filename
                try ArcKitRecord.save(settings, layout: AppBackgroundSettings.recordLayout, db: db)
            }
        }
        let updated = StorageBackupManifest(format: manifest.format, createdAt: manifest.createdAt,
            includesAssets: manifest.includesAssets, files: entries)
        try JSONEncoder().encode(updated).write(to: manifestURL)
    }

    private func makeImage(in root: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let url = root.appendingPathComponent("wallpaper.png")
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        try #require(CGImageDestinationFinalize(output))
        return url
    }
}
