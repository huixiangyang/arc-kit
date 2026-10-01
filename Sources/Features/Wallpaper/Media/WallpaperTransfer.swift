import Foundation

/// 浏览来源只提供素材描述；图片、视频和直链共用一条下载入库与应用流程。
struct WallpaperRemoteAsset: Sendable {
    let title: String
    let url: URL
    let kind: WallpaperKind
    var origin: WallpaperOrigin

    init(title: String, url: URL, kind: WallpaperKind, origin: WallpaperOrigin) {
        self.title = title; self.url = url; self.kind = kind; self.origin = origin
        self.origin.imageURL = url
    }
    init(_ image: OnlineWallpaper) {
        self.init(title: image.title, url: image.imageURL, kind: .image, origin: image.origin)
    }
    init(_ video: MotionWallpaper, variant: MotionVariant) {
        self.init(title: video.title, url: variant.url, kind: .video, origin: video.origin)
    }
}

@MainActor
enum WallpaperDestination {
    case library
    case desktop(WallpaperDesktopRequest)
    case background(WallpaperBackgroundAction)
}

/// 壁纸只交付已入库的素材，应用负责把它接到外观保存事务。
@MainActor
struct WallpaperBackgroundAction {
    let isAvailable: Bool
    let apply: (URL, WallpaperKind) async throws -> Void
}
