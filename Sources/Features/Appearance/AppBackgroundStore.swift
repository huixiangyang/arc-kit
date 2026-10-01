import ArcKitPersistence
import ArcKitPlatform
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AppBackgroundStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, aura, image, video
    var id: Self { self }
    var title: String { switch self { case .system: L10n.string(.AppBackground.backgroundStorageSystem); case .aura: L10n.string(.AppBackground.backgroundStorageSoftGlow); case .image: L10n.string(.AppBackground.backgroundStorageImage); case .video: L10n.string(.AppBackground.backgroundStorageVideo) } }
}

struct AppBackgroundSettings: Codable, Equatable, Sendable {
    var style: AppBackgroundStyle = .system
    var imageID: String?
    var imageName: String?
    var videoFilename: String?
    var opacity = 0.75
    var blur = 0.0
    var dimming = 0.2
    var aura = AuraSettings()
    var themes: [AuraTheme] = []

    /// 明确设置一张新壁纸时恢复清晰效果，不沿用上一张的重度模糊参数。
    mutating func restoreMediaClarity() {
        let defaults = Self()
        opacity = defaults.opacity; blur = defaults.blur; dimming = defaults.dimming
    }

    func validated() throws -> Self {
        guard opacity.isFinite, (0.05...1).contains(opacity),
              blur.isFinite, (0...60).contains(blur),
              dimming.isFinite, (0...0.85).contains(dimming),
              imageID.map({ $0.count == 64 && $0.allSatisfy({ $0.isASCII && $0.isHexDigit }) }) ?? true,
              style != .image || imageID != nil,
              style != .video || (imageID != nil && videoFilename != nil),
              videoFilename.map({ name in
                  ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: name).pathExtension)
                      && URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.count == 64
                      && URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.allSatisfy({ $0.isASCII && $0.isHexDigit })
                      && !name.contains("/")
              }) ?? true,
              (imageName?.count ?? 0) <= 300 else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageInvalidSettings))
        }
        try aura.validate(themes: themes)
        return self
    }
}

/// 应用背景拥有自己的图片副本和事务域，不依赖原图路径或桌面壁纸分配。
actor AppBackgroundStore {
    struct Snapshot: Sendable {
        let settings: AppBackgroundSettings
        let imageData: Data?
        let imageError: String?
        var videoURL: URL? = nil
    }

    nonisolated let directory: URL
    nonisolated let database: ArcKitDatabase
    private var generation: Int64 = 0
    init(database: ArcKitDatabase) { self.database = database; self.directory = database.paths.root }
    func imageURL(_ id: String) throws -> URL {
        let path = try database.read { try String.fetchOne($0, sql: "SELECT path FROM assets WHERE digest=?", arguments: [id]) }
        guard let path, path.hasPrefix("assets/media/" + id + "."),
              !path.dropFirst("assets/media/".count).contains("/") else { throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageInvalidAssetIndex)) }
        return database.paths.root.appendingPathComponent(path)
    }

    func load() throws -> Snapshot {
        let decoded = try database.read { db in
            guard let value = try ArcKitRecord.load(AppBackgroundSettings.self, layout: AppBackgroundSettings.recordLayout, db: db) else { throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageRecordMissing)) }
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='background'") ?? 0
            return (try value.validated(), revision)
        }
        generation = decoded.1
        guard let id = decoded.0.imageID else { return Snapshot(settings: decoded.0, imageData: nil, imageError: nil) }
        do {
            let data = try ArcKitBoundedFileReader.read(from: imageURL(id), maximumBytes: 24 * 1_024 * 1_024)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw CocoaError(.fileReadCorruptFile) }
            let video = decoded.0.videoFilename.map { database.paths.media.appendingPathComponent($0) }
            let readable = video.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? true
            return Snapshot(settings: decoded.0, imageData: data,
                imageError: readable ? nil : L10n.string(.AppBackground.backgroundStorageVideoUnreadable), videoURL: readable ? video : nil)
        } catch {
            // 图片丢失时保留配置和恢复副本；界面显示柔光底色并提供重新选图。
            return Snapshot(settings: decoded.0, imageData: nil, imageError: L10n.string(.AppBackground.backgroundStorageImageUnreadable))
        }
    }

    func save(_ settings: AppBackgroundSettings) throws {
        let candidate = try settings.validated()
        if candidate.style == .image || candidate.style == .video, let id = candidate.imageID,
           try !FileManager.default.isReadableFile(atPath: imageURL(id).path) {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageImageMissing))
        }
        if candidate.style == .video, let filename = candidate.videoFilename,
           !FileManager.default.isReadableFile(atPath: database.paths.media.appendingPathComponent(filename).path) {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageBackgroundVideoMissingChoose))
        }
        try database.write { db in
            let current = try Int64.fetchOne(db, sql: "SELECT revision FROM domain_revisions WHERE domain='background'") ?? 0
            guard current == generation else { throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageConcurrentChange)) }
            try ArcKitRecord.save(candidate, layout: AppBackgroundSettings.recordLayout, db: db)
            try db.execute(sql: "INSERT INTO domain_revisions VALUES('background',?) ON CONFLICT(domain) DO UPDATE SET revision=excluded.revision", arguments: [current + 1])
            try ArcKitDatabase.advance(db)
        }
        generation += 1
        // 资源可能仍被桌面、图库或备份引用；切换背景时只提交引用，不立即删文件。
    }

    func importImage(_ url: URL, settings: AppBackgroundSettings) throws -> Snapshot {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let sourceURL = url.resolvingSymlinksInPath()
        let info = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard sourceURL.isFileURL, info.isRegularFile == true,
              let fileBytes = info.fileSize, fileBytes > 0, fileBytes <= 100 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 150_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageInvalidImage))
        }
        try Task.checkCancellation()
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        let data = bytes as Data
        let imported = try ArcKitAssetStore(database: database).importData(data, extension: "jpg")
        let id = imported.digest
        var next = settings
        next.style = .image; next.imageID = id; next.videoFilename = nil
        next.imageName = String(url.deletingPathExtension().lastPathComponent.prefix(300))
        try Task.checkCancellation()
        try save(next)
        return Snapshot(settings: next, imageData: data, imageError: nil)
    }

    func importVideo(_ url: URL, settings: AppBackgroundSettings) async throws -> Snapshot {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let ext = url.pathExtension.lowercased()
        guard url.isFileURL, info.isRegularFile == true, let bytes = info.fileSize,
              bytes > 0, bytes <= 2_147_483_648, ["mp4", "mov", "m4v"].contains(ext) else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageChooseMp4MovM4VVideo))
        }
        try Task.checkCancellation()
        let imported = try ArcKitAssetStore(database: database).importFile(url)
        let file = imported.url
        let asset = AVURLAsset(url: file)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.backgroundStorageVideoPlayableVideoTrackMissing))
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2560, height: 2560)
        let image = try await generator.image(at: .zero).image
        let buffer = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        let data = buffer as Data
        let poster = try ArcKitAssetStore(database: database).importData(data, extension: "jpg")
        var next = settings
        next.style = .video; next.imageID = poster.digest; next.videoFilename = file.lastPathComponent
        next.imageName = String(url.deletingPathExtension().lastPathComponent.prefix(300))
        try Task.checkCancellation()
        try save(next)
        return Snapshot(settings: next, imageData: data, imageError: nil, videoURL: file)
    }

}

extension AppBackgroundSettings {
    static let recordLayout = ArcKitRecordLayout("background_preferences", fields: ["style", "imageID", "imageName", "videoFilename", "opacity", "blur", "dimming", "aura"],
        json: ["aura"], children: ["themes": ArcKitRecordLayout("background_themes",
            fields: ["id", "name", "form", "light", "dark", "seed", "spread", "x", "y", "motion", "particles", "grain"], json: ["light", "dark"])])
}
