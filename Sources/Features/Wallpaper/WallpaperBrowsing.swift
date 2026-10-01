import ArcKitPlatform
import Combine
import Foundation

enum WallpaperLibraryFilter: String, CaseIterable {
    case all, images, videos, favorites
    var title: String { switch self { case .all: L10n.string(.Common.all); case .images: L10n.string(.AppBackground.backgroundStorageImage); case .videos: L10n.string(.AppBackground.backgroundStorageVideo); case .favorites: L10n.string(.Common.favorites) } }
}
enum WallpaperLibrarySort: String, CaseIterable {
    case newest, name, resolution
    var title: String { switch self { case .newest: L10n.string(.Wallpaper.browseRecentlyAdded); case .name: L10n.string(.Common.name); case .resolution: L10n.string(.Wallpaper.browseResolution) } }
}

/// 页面局部状态与图库事务分离，切换标签保留检索词、筛选、排序和已加载页。
@MainActor
final class WallpaperBrowsing: ObservableObject {
    @Published var localQuery = ""
    @Published var localFilter: WallpaperLibraryFilter = .all
    @Published var localSort: WallpaperLibrarySort = .newest
    let images = WallpaperMixedBrowser<OnlineWallpaper>.images()
    let videos = WallpaperMixedBrowser<MotionWallpaper>.videos()

    func localItems(in catalog: WallpaperCatalog) -> [WallpaperItem] {
        let query = localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.items.filter { item in
            (localFilter == .all || localFilter == .images && item.kind == .image
             || localFilter == .videos && item.kind == .video || localFilter == .favorites && item.isFavorite)
            && (query.isEmpty || "\(item.name) \(item.origin?.provider ?? "")".localizedCaseInsensitiveContains(query))
        }.sorted { left, right in
            switch localSort {
            case .newest: if left.addedAt != right.addedAt { return left.addedAt > right.addedAt }
            case .name:
                let order = left.name.localizedStandardCompare(right.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .resolution:
                let l = Double(left.width) * Double(left.height), r = Double(right.width) * Double(right.height)
                if l != r { return l > r }
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
    func stop() { images.stop(); videos.stop() }
}
