import ArcKitPlatform

enum WallpaperFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .wallpaper, title: L10n.string(.Common.wallpaper), icon: .image, commands: { commands })
    }

    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "section.wallpaper", L10n.string(.Common.wallpaper), L10n.string(.App.searchLocalImagesVideoWallpapersOnlineGallery), .image, L10n.string(.App.searchPages),
                ["壁纸", "桌面", "背景", "图片", "视频", "动态", "wallpaper", "background", "Wallhaven", "Bing"], .section(.wallpaper), suggested: true, order: 35
            ),
            ArcKitQuickCommand.command(
                "wallpaper.motion", L10n.string(.App.searchLiveWallpaperGallery), L10n.string(.App.searchVideoPreviewsFeedsDownloadsAppBackgrounds), .image, L10n.string(.Common.wallpaper),
                ["动态图库", "视频", "订阅", "NASA", "MotionBGS", "循环"], .wallpaper(.motion), order: 36
            ),
            ArcKitQuickCommand.command(
                "wallpaper.displays", L10n.string(.App.searchWallpaperDisplaysPlayback), L10n.string(.App.searchPerDisplayWallpapersScalingRotationScope), .monitor, L10n.string(.Common.wallpaper),
                ["多屏", "显示器", "屏幕", "轮换", "播放设置", "monitor", "display"], .wallpaper(.playback), order: 37
            )
        ]
    }
}
