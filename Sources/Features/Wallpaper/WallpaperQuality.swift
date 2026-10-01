import ArcKitPlatform
import Foundation

/// 壁纸档位按长短边共同判断；竖图与横图相同，超宽图不能只因长边较长就升为 4K。
enum WallpaperQuality: Int, Comparable, Sendable {
    case unknown, sd, hd, p720, p1080, k2, k4, k5, k6, k8

    var title: String {
        switch self {
        case .unknown: L10n.string(.WallpaperMedia.qualityUnspecified)
        case .sd: "SD"
        case .hd: "HD"
        case .p720: "720p"
        case .p1080: "1080p"
        case .k2: "2K"
        case .k4: "4K"
        case .k5: "5K"
        case .k6: "6K"
        case .k8: "8K"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func dimensions(width: Int, height: Int) -> Self? {
        guard width > 0, height > 0 else { return nil }
        let long = max(width, height), short = min(width, height)
        let tiers: [(Int, Int, Self)] = [(7680, 4320, .k8), (5760, 3240, .k6), (5120, 2880, .k5),
            (3840, 2160, .k4), (2560, 1440, .k2), (1920, 1080, .p1080), (1280, 720, .p720)]
        return tiers.first { long >= $0.0 && short >= $0.1 }?.2 ?? .sd
    }

    /// 只解析来源的清晰度字段/版本说明，不从作品标题、缩略图尺寸或 URL 猜测。
    static func declared(_ text: String) -> Self? {
        let text = String(text.prefix(500))
        if let regex = try? NSRegularExpression(pattern: #"(?<!\d)(\d{2,5})\s*[x×]\s*(\d{2,5})(?!\d)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let w = Range(match.range(at: 1), in: text), let h = Range(match.range(at: 2), in: text),
           let width = Int(text[w]), let height = Int(text[h]) {
            return dimensions(width: width, height: height)
        }
        let aliases: [(String, Self)] = [("8K|4320p", .k8), ("6K|3240p", .k6), ("5K|2880p", .k5),
            ("4K|2160p|UHD", .k4), ("2K|1440p|QHD", .k2), ("1080p|FHD", .p1080),
            ("720p", .p720), ("HD", .hd), ("SD", .sd)]
        return aliases.first { text.range(of: "(?i)\\b(?:" + $0.0 + ")\\b", options: .regularExpression) != nil }?.1
    }
}

extension OnlineWallpaper {
    var quality: WallpaperQuality? { .dimensions(width: width, height: height) }
}
