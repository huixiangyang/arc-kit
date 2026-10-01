import ArcKitPlatform
import SwiftUI

struct WallpaperOnlineView: View {
    @ObservedObject var model: WallpaperModel
    let background: WallpaperBackgroundAction
    @ObservedObject private var browser: WallpaperMixedBrowser<OnlineWallpaper>
    @State private var selected: OnlineWallpaper?

    init(model: WallpaperModel, background: WallpaperBackgroundAction, browser: WallpaperMixedBrowser<OnlineWallpaper>? = nil) {
        self.model = model; self.background = background; self.browser = browser ?? model.browsing.images
    }
    var body: some View {
        WallpaperRemoteGallery(browser: browser, channels: model.channels, kind: .image,
            searchHint: L10n.string(.WallpaperSources.onlineWallhavenCommonsSupportOnlineSearchDaily)) {
            EmptyView()
        } card: { item in
            Button { selected = item } label: {
                WallpaperGalleryCard(title: item.title, subtitle: "\(item.width) × \(item.height)", badge: item.origin.provider,
                    quality: item.quality,
                    downloaded: model.downloadedItem(WallpaperRemoteAsset(item)) != nil) {
                    WallpaperRemoteImage(url: item.thumbnailURL)
                }
            }.buttonStyle(.plain).accessibilityLabel(L10n.string(.WallpaperSources.onlineViewImageDetails(String(describing: item.title), String(describing: item.quality?.title ?? L10n.string(.WallpaperSources.motionQualitySpecifiedUnavailable)), String(describing: item.origin.provider))))
        }
        .sheet(item: $selected) { WallpaperOnlineDetail(model: model, background: background, item: $0) }
    }
}

struct WallpaperOnlineDetail: View {
    @ObservedObject var model: WallpaperModel
    let background: WallpaperBackgroundAction
    let item: OnlineWallpaper
    @State private var showsApply = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WallpaperDetailPanel(title: item.title, subtitle: "\(item.width) × \(item.height) · \(item.origin.provider)") {
            Color.primary.opacity(0.045).aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { ArcIcon(.image, size: 28).foregroundStyle(.tertiary) }
                        else { ProgressView().controlSize(.small) }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            WallpaperSourceAttribution(origin: item.origin)
            WallpaperApplyFeedback(model: model)
            Text(model.downloadedItem(WallpaperRemoteAsset(item)) == nil ? L10n.string(.WallpaperSources.onlineDownloadsStoredIndependentCopies) : L10n.string(.WallpaperSources.onlineImageAlreadyLibrary))
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            HStack(spacing: 10) {
                Button(model.downloadedItem(WallpaperRemoteAsset(item)) == nil ? L10n.string(.WallpaperSources.motionDownloadLibrary) : L10n.string(.WallpaperSources.onlineLibrary)) { model.download(WallpaperRemoteAsset(item), to: .library); dismiss() }
                Spacer(minLength: 0)
                Button(L10n.string(.WallpaperSources.motionSetAppBackground)) { model.download(WallpaperRemoteAsset(item), to: .background(background)); dismiss() }
                    .buttonStyle(.bordered).disabled(!background.isAvailable)
                Button(L10n.string(.WallpaperSources.motionSetDesktopWallpaper)) { showsApply = true }
                    .buttonStyle(.borderedProminent).tint(.blue).disabled(model.isPreview)
            }.disabled(model.isBusy || !model.isLoaded)
        }
        .sheet(isPresented: $showsApply) {
            WallpaperApplySheet(model: model, title: item.title) { model.download(WallpaperRemoteAsset(item), to: .desktop($0)) }
        }
    }
}
