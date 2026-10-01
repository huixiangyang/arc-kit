import Foundation

/// 两个功能只在应用装配处相识，壁纸库不读取或修改外观模型。
@MainActor
enum WallpaperBackgroundIntegration {
    static func action(for background: AppBackgroundModel) -> WallpaperBackgroundAction {
        WallpaperBackgroundAction(isAvailable: background.isLoaded && !background.isBusy) { url, kind in
            try await background.applyMedia(url, video: kind == .video)
        }
    }
}
