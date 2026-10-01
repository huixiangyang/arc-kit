import ArcKitPlatform
import Combine
import SwiftUI

struct MotionWallpaperView: View {
    @ObservedObject var model: WallpaperModel
    let background: WallpaperBackgroundAction
    @ObservedObject private var gallery: WallpaperMixedBrowser<MotionWallpaper>
    @StateObject private var browser = MotionWallpaperSelection()
    @State private var showDetail = false
    @State private var pendingLink: String?
    @State private var showLink = false
    @State private var input = ""

    init(model: WallpaperModel, background: WallpaperBackgroundAction, gallery: WallpaperMixedBrowser<MotionWallpaper>? = nil) {
        self.model = model; self.background = background; self.gallery = gallery ?? model.browsing.videos
    }
    var body: some View {
        WallpaperRemoteGallery(browser: gallery, channels: model.channels, kind: .video,
            searchHint: L10n.string(.WallpaperSources.motionNasaSupportsOnlineSearchEnglishKeywordsWork)) {
            Button { input = ""; showLink = true } label: { ArcIcon(.plus, size: 14) }
                .help(L10n.string(.WallpaperSources.motionParseVideoLink)).accessibilityLabel(L10n.string(.WallpaperSources.motionParseVideoLink))
        } card: { item in
            Button { browser.choose(item); showDetail = true } label: {
                WallpaperGalleryCard(title: item.title, subtitle: L10n.string(.WallpaperSources.motionVideoWallpaper), badge: item.origin.provider, quality: item.quality ?? .unknown) {
                    WallpaperRemoteImage(url: item.thumbnail)
                }
            }.buttonStyle(.plain).accessibilityLabel(L10n.string(.WallpaperSources.motionPreviewVideo(String(describing: item.title), String(describing: item.quality.map { L10n.string(.WallpaperSources.motionMaximum) + $0.title } ?? L10n.string(.WallpaperSources.motionQualitySpecifiedUnavailable)), String(describing: item.origin.provider))))
        }
        .onDisappear { browser.dismissSelection() }
        .sheet(isPresented: $showDetail, onDismiss: browser.dismissSelection) {
            MotionWallpaperDetail(model: model, background: background, browser: browser)
        }
        .sheet(isPresented: $showLink, onDismiss: {
            if let pendingLink { browser.link(pendingLink); self.pendingLink = nil; showDetail = true }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string(.WallpaperSources.motionParseVideoLink)).font(.headline)
                TextField("https://…", text: $input).textFieldStyle(.roundedBorder)
                Text(L10n.string(.WallpaperSources.motionSupportsMotionbgsPagesDirectMp4Mov))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.string(.Common.cancel)) { showLink = false }
                    Button(L10n.string(.WallpaperSources.motionParse)) { pendingLink = input; showLink = false }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 460)
        }
    }
}

struct MotionWallpaperDetail: View {
    @ObservedObject var model: WallpaperModel
    let background: WallpaperBackgroundAction
    @ObservedObject var browser: MotionWallpaperSelection
    @State private var variantID = ""
    @State private var showsApply = false
    @Environment(\.dismiss) private var dismiss

    private var variant: MotionVariant? {
        browser.selected?.variants.first(where: { $0.id == variantID }) ?? browser.selected?.variants.first
    }

    var body: some View {
        WallpaperDetailPanel(title: browser.selected?.title ?? L10n.string(.WallpaperSources.motionVideoDetails), subtitle: browser.selected?.origin.provider ?? L10n.string(.WallpaperSources.motionParsingLink)) {
            if let item = browser.selected {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        WallpaperVideoPreview(url: item.preview ?? item.variants.first?.url)
                            .id(item.id + (item.preview?.absoluteString ?? ""))
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                if browser.resolving { ProgressView(L10n.string(.WallpaperSources.motionReadingQualityOptions)).controlSize(.small) }
                else if !item.variants.isEmpty {
                    HStack {
                        Text(L10n.string(.WallpaperSources.motionDownloadQuality)).font(.callout)
                        Spacer()
                        Picker(L10n.string(.WallpaperSources.motionDownloadQuality), selection: Binding(get: { variant?.id ?? "" }, set: { variantID = $0 })) {
                            ForEach(item.variants) { Text($0.title).tag($0.id) }
                        }.labelsHidden().frame(width: 220)
                    }
                }
                WallpaperSourceAttribution(origin: item.origin)
                WallpaperApplyFeedback(model: model)
            } else if browser.resolving {
                WallpaperGalleryState(title: L10n.string(.WallpaperSources.motionParsingVideo), message: L10n.string(.WallpaperSources.motionFetchingPreviewAvailableDownloadQualities), loading: true)
            }
            if let error = browser.detailError {
                HStack(alignment: .top, spacing: 8) {
                    ArcIcon(.triangleAlert, size: 14)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let item = browser.selected { Button(L10n.string(.Common.retry)) { browser.choose(item) } }
                }.foregroundStyle(.orange)
            }
        } actions: {
            HStack(spacing: 10) {
                Button(L10n.string(.WallpaperSources.motionDownloadLibrary)) { download(.library) }
                Spacer(minLength: 0)
                Button(L10n.string(.WallpaperSources.motionSetAppBackground)) { download(.background(background)) }
                    .buttonStyle(.bordered).disabled(!background.isAvailable)
                Button(L10n.string(.WallpaperSources.motionSetDesktopWallpaper)) { showsApply = true }
                    .buttonStyle(.borderedProminent).tint(.blue).disabled(model.isPreview)
            }.disabled(browser.resolving || variant == nil || model.isBusy || !model.isLoaded)
        }
        .sheet(isPresented: $showsApply) {
            WallpaperApplySheet(model: model, title: browser.selected?.title ?? L10n.string(.WallpaperMedia.libraryLiveWallpaper)) { request in
                guard let item = browser.selected, let variant else { return nil }
                return model.download(WallpaperRemoteAsset(item, variant: variant), to: .desktop(request))
            }
        }
    }

    private func download(_ target: WallpaperDestination) {
        guard let item = browser.selected, let variant else { return }
        model.download(WallpaperRemoteAsset(item, variant: variant), to: target)
        dismiss()
    }
}

/// 详情解析与图库加载分开，分页或渠道刷新不打断用户正在预览的视频。
@MainActor
final class MotionWallpaperSelection: ObservableObject {
    @Published var selected: MotionWallpaper?
    @Published var resolving = false
    @Published var detailError: String?
    private var detailWork: Task<Void, Never>?
    private var selection = UUID()
    func choose(_ item: MotionWallpaper) {
        detailWork?.cancel()
        let token = UUID(); selection = token
        selected = item; resolving = true; detailError = nil
        detailWork = Task { [weak self] in
            do {
                let result = try await MotionWallpaperSource.resolve(item)
                guard let self, selection == token, !Task.isCancelled else { return }
                selected = result; resolving = false
            } catch {
                guard let self, selection == token, !Task.isCancelled else { return }
                detailError = error.localizedDescription; resolving = false
            }
        }
    }
    func link(_ text: String) {
        dismissSelection()
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { detailError = L10n.string(.WallpaperSources.motionInvalidLinkEnterCompleteHttpsUrl); return }
        let token = UUID(); selection = token
        resolving = true; detailError = nil; selected = nil
        detailWork = Task { [weak self] in
            do {
                let item = try await MotionWallpaperSource.fromLink(url)
                guard let self, selection == token, !Task.isCancelled else { return }
                selected = item; resolving = false
            } catch {
                guard let self, selection == token, !Task.isCancelled else { return }
                detailError = error.localizedDescription; resolving = false
            }
        }
    }
    func dismissSelection() {
        detailWork?.cancel(); selection = UUID()
        selected = nil; resolving = false; detailError = nil
    }
}
