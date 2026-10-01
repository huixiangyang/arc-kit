import ArcKitPlatform
import Foundation

enum WallpaperKind: String, Codable, Sendable { case image, video }

enum WallpaperScaling: String, CaseIterable, Codable, Identifiable, Sendable {
    case fill, fit, stretch
    var id: Self { self }
    var title: String {
        switch self { case .fill: L10n.string(.WallpaperMedia.mediaFillScreen); case .fit: L10n.string(.WallpaperMedia.mediaFitScreen); case .stretch: L10n.string(.WallpaperMedia.mediaStretch) }
    }
}

enum WallpaperInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fiveMinutes = 300, fifteenMinutes = 900, halfHour = 1800, hour = 3600, day = 86400
    var id: Self { self }
    var title: String {
        switch self {
        case .fiveMinutes: L10n.string(.WallpaperPlayback.intervalFiveMinutes)
        case .fifteenMinutes: L10n.string(.WallpaperPlayback.intervalFifteenMinutes)
        case .halfHour: L10n.string(.WallpaperPlayback.intervalThirtyMinutes)
        case .hour: L10n.string(.WallpaperPlayback.intervalHour)
        case .day: L10n.string(.WallpaperMedia.mediaDaily)
        }
    }
}

struct WallpaperOrigin: Codable, Equatable, Sendable {
    var provider: String
    var pageURL: URL
    var author: String?
    var license: String?
    var imageURL: URL?
}

struct WallpaperItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let fileExtension: String
    let kind: WallpaperKind
    let width: Int
    let height: Int
    let byteCount: Int64
    let digest: String
    let addedAt: Date
    var origin: WallpaperOrigin?
    var isFavorite = false
    var filename: String { "\(digest).\(fileExtension)" }
    var dimensions: String { "\(width) × \(height)" }
}

struct WallpaperAssignment: Codable, Equatable, Sendable {
    var itemID: UUID
    var scaling: WallpaperScaling
}

struct WallpaperPreferences: Codable, Equatable, Sendable {
    /// 仅控制轮换范围与缩放；手动应用必须提供独立的屏幕快照。
    var displayID = "all"
    var scaling: WallpaperScaling = .fill
    var rotationEnabled = false
    var interval: WallpaperInterval = .halfHour
    var shuffle = true
    var favoritesOnly = false
}

struct WallpaperCatalog: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case items, preferences, assignments }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([WallpaperItem].self, forKey: .items)
        preferences = try c.decode(WallpaperPreferences.self, forKey: .preferences)
        assignments = try c.decodeIfPresent([String: WallpaperAssignment].self, forKey: .assignments) ?? [:]
    }
    var items: [WallpaperItem] = []
    var preferences = WallpaperPreferences()
    var assignments: [String: WallpaperAssignment] = [:]

    func validated() throws -> Self {
        let extensions = Set(["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp", "mp4", "mov", "m4v"])
        guard items.count <= 2_000, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ extensions.contains($0.fileExtension) && $0.width > 0 && $0.height > 0
                  && $0.byteCount > 0 && $0.digest.count == 64 && $0.digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) }),
              preferences.displayID == "all" || UUID(uuidString: preferences.displayID) != nil,
              assignments.allSatisfy({ assignment in
                  UUID(uuidString: assignment.key) != nil && items.contains(where: { $0.id == assignment.value.itemID })
              }) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.mediaInvalidWallpaperLibraryFormatPreserveFile))
        }
        return self
    }

    func rotationCandidates(excluding current: Set<UUID>) -> [WallpaperItem] {
        let pool = items.filter { !preferences.favoritesOnly || $0.isFavorite }
        let alternatives = pool.filter { !current.contains($0.id) }
        return alternatives.isEmpty ? pool : alternatives
    }
}

struct WallpaperDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    var frame: CGRect = .zero
    var isPrimary = false
}

/// 在用户确认时固定目标。下载、解码期间新增的屏幕不能被隐式加入。
struct WallpaperDesktopRequest: Equatable, Sendable {
    let displayIDs: Set<String>
    let scaling: WallpaperScaling

    func validate(connected: Set<String>) throws {
        guard !displayIDs.isEmpty else { throw WallpaperError.message(L10n.string(.WallpaperMedia.mediaChooseDisplayWallpaperFirst)) }
        guard displayIDs.isSubset(of: connected) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.mediaSelectedDisplayDisconnectedSelectAgainMissing))
        }
    }
}

enum WallpaperProvider: String, CaseIterable, Identifiable, Sendable {
    case wallhaven = "Wallhaven"
    case commons = "Wikimedia Commons"
    case bing = "Bing"
    case picsum = "Lorem Picsum"
    var id: Self { self }
    var title: String { self == .bing ? L10n.string(.WallpaperMedia.mediaBingDailyWallpaper) : rawValue }
    var supportsSearch: Bool { self == .wallhaven || self == .commons }
}

struct OnlineWallpaper: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let imageURL: URL
    let thumbnailURL: URL
    let width: Int
    let height: Int
    let origin: WallpaperOrigin
}

struct WallpaperSearchPage: Sendable {
    let items: [OnlineWallpaper]
    let hasNextPage: Bool
}

enum WallpaperError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case let .message(text): text } }
}

struct WallpaperFeedback: Equatable {
    enum Kind { case success, notice, failure, cancelled }
    let message: String
    let kind: Kind
}

extension WallpaperCatalog {
    static let recordLayout = ArcKitRecordLayout("wallpaper_preferences", fields: ["preferences.displayID", "preferences.scaling", "preferences.rotationEnabled", "preferences.interval", "preferences.shuffle", "preferences.favoritesOnly"], children: [
        "items": ArcKitRecordLayout("wallpaper_items", fields: ["id", "name", "fileExtension", "kind", "width", "height", "byteCount", "digest", "addedAt", "origin", "isFavorite"], json: ["origin"])
    ])
}
