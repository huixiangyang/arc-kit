import ArcKitPersistence
import ArcKitPlatform
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 大文件复制、解码与缩略图生成留在 actor；提交成功后界面才收到新目录。
actor WallpaperLibrary {
    nonisolated let directory: URL
    nonisolated let database: ArcKitDatabase
    private var generation: Int64 = 0

    init(database: ArcKitDatabase) {
        self.database = database; self.directory = database.paths.root
    }
    nonisolated func mediaURL(_ item: WallpaperItem) -> URL { database.paths.media.appendingPathComponent(item.filename) }
    nonisolated func thumbnailURL(_ item: WallpaperItem) -> URL { database.paths.thumbnails.appendingPathComponent("\(item.digest).jpg") }

    func load() throws -> WallpaperCatalog {
        try database.read { db in
            guard var result = try ArcKitRecord.load(WallpaperCatalog.self, layout: WallpaperCatalog.recordLayout, db: db) else { throw WallpaperError.message(L10n.string(.Wallpaper.libraryWallpaperConfigurationRecordMissing)) }
            result.assignments = try Self.assignments(db)
            generation = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='wallpaper'") ?? 0
            return try result.validated()
        }
    }
    func save(_ catalog: WallpaperCatalog) throws -> WallpaperCatalog {
        let candidate = try catalog.validated()
        try database.write { db in
            let current = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='wallpaper'") ?? 0
            guard current == generation else { throw WallpaperError.message(L10n.string(.Wallpaper.libraryWallpaperLibraryChangedElsewhereReload)) }
            try ArcKitRecord.save(candidate, layout: WallpaperCatalog.recordLayout, db: db)
            try db.execute(sql: "DELETE FROM display_wallpapers")
            for (display, assignment) in candidate.assignments {
                try db.execute(sql: "INSERT INTO display_wallpapers VALUES(?,?,?)", arguments: [display, assignment.itemID.uuidString, assignment.scaling.rawValue])
            }
            try db.execute(sql: "INSERT INTO domain_revisions VALUES('wallpaper',?) ON CONFLICT(domain) DO UPDATE SET revision=excluded.revision", arguments: [current + 1])
            try ArcKitDatabase.advance(db)
        }
        generation += 1
        return candidate
    }
    private static func assignments(_ db: Database) throws -> [String: WallpaperAssignment] {
        var result: [String: WallpaperAssignment] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM display_wallpapers") {
            guard let id = UUID(uuidString: row["item_id"]), let scaling = WallpaperScaling(rawValue: row["scaling"]) else { throw WallpaperError.message(L10n.string(.WallpaperPlayback.libraryInvalidDisplayAssignmentFormat)) }
            result[row["display_id"]] = WallpaperAssignment(itemID: id, scaling: scaling)
        }
        return result
    }

    struct ImportResult: Sendable {
        let catalog: WallpaperCatalog
        let imported: Int
        let duplicates: Int
        let repaired: Int
        let failures: [String]
        let itemID: UUID?
    }

    func importFiles(_ urls: [URL], into original: WallpaperCatalog, origin: WallpaperOrigin? = nil) async throws -> ImportResult {
        guard urls.count <= 100, original.items.count <= 2_000 else {
            throw WallpaperError.message(L10n.string(.Wallpaper.importFileLimit))
        }
        try FileManager.default.createDirectory(at: database.paths.media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: database.paths.thumbnails, withIntermediateDirectories: true)
        var candidate = original
        var failures: [String] = []
        var duplicates = 0
        var repaired = 0
        var imported = 0
        var itemID: UUID?
        // 缩略图按内容共享，失败或取消不能删掉另一笔成功导入正在使用的缓存。
        // 未被引用的缓存交由存储维护清理，原文件和不可变媒体副本始终保留。
        for url in urls {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard url.isFileURL, resource.isRegularFile == true,
                      let bytes = resource.fileSize, bytes > 0, bytes <= 2_147_483_648 else {
                    throw WallpaperError.message(L10n.string(.Wallpaper.libraryChooseLocalImageVideoMissing))
                }
                let ext = url.pathExtension.lowercased()
                let video = ["mp4", "mov", "m4v"].contains(ext)
                guard video || ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext) else {
                    throw WallpaperError.message(L10n.string(.Wallpaper.librarySupportsJpgPngHeicWebpTiffBmp))
                }
                let id = UUID()
                let sourceDigest = try Self.digest(url)
                let missing = candidate.items.first(where: { $0.digest == sourceDigest }).map { !FileManager.default.fileExists(atPath: mediaURL($0).path) } ?? false
                let stored = try ArcKitAssetStore(database: database).importFile(url)
                let destination = stored.url
                let digest = stored.digest
                if let existing = candidate.items.first(where: { $0.digest == digest }) {
                    let rebuilt = try await rebuildThumbnail(existing)
                    itemID = existing.id
                    if missing || rebuilt { repaired += 1 } else { duplicates += 1 }
                    continue
                }
                guard candidate.items.count < 2_000 else { throw WallpaperError.message(L10n.string(.Wallpaper.libraryCapacityLimit)) }
                let thumbnail: CGImage
                let width: Int
                let height: Int
                if video {
                    let asset = AVURLAsset(url: destination)
                    guard try await asset.load(.isPlayable),
                          let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw WallpaperError.message(L10n.string(.WallpaperMedia.libraryVideoPlayableVideoTrackMissing))
                    }
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: size).applying(transform)
                    width = Int(abs(oriented.width)); height = Int(abs(oriented.height))
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 800, height: 800)
                    thumbnail = try await generator.image(at: .zero).image
                } else {
                    guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = properties[kCGImagePropertyPixelWidth] as? Int,
                          let h = properties[kCGImagePropertyPixelHeight] as? Int,
                          w > 0, h > 0, Double(w) * Double(h) <= 150_000_000,
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 800,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else {
                        throw WallpaperError.message(L10n.string(.Wallpaper.importInvalidImage))
                    }
                    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                    width = (5...8).contains(orientation) ? h : w
                    height = (5...8).contains(orientation) ? w : h
                    thumbnail = image
                }
                let item = WallpaperItem(id: id, name: url.deletingPathExtension().lastPathComponent,
                    fileExtension: stored.url.pathExtension, kind: video ? .video : .image, width: width, height: height,
                    byteCount: Int64(bytes), digest: digest, addedAt: Date(), origin: origin)
                try writeThumbnail(thumbnail, to: thumbnailURL(item))
                candidate.items.append(item)
                itemID = item.id
                imported += 1
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        try Task.checkCancellation()
        if imported > 0 { candidate = try save(candidate) }
        return ImportResult(catalog: candidate, imported: imported, duplicates: duplicates, repaired: repaired, failures: failures, itemID: itemID)
    }

    @discardableResult
    func rebuildThumbnail(_ item: WallpaperItem) async throws -> Bool {
        try Task.checkCancellation()
        let destination = thumbnailURL(item)
        // 存在不代表可用：清缓存中断或磁盘损坏也可能留下无法解码的文件。
        if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
           CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil {
            return false
        }
        let image: CGImage
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL(item)))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 800, height: 800)
            image = try await generator.image(at: .zero).image
        } else {
            guard let source = CGImageSourceCreateWithURL(mediaURL(item) as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 800] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = thumbnail
        }
        try writeThumbnail(image, to: destination)
        return true
    }

    private func writeThumbnail(_ image: CGImage, to destination: URL) throws {
        try Task.checkCancellation()
        let buffer = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        try ArcKitAtomicFile.writeAtomically(buffer as Data, to: destination)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
