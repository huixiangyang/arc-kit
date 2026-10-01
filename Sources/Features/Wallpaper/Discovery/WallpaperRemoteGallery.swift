import ArcKitPlatform
import SwiftUI

/// 图片和视频共用工具栏、状态、错误与分页；详情和来源解析由各自页面提供。
struct WallpaperRemoteGallery<Item: Identifiable & Sendable, Card: View, Tools: View>: View where Item.ID: Sendable {
    @ObservedObject var browser: WallpaperMixedBrowser<Item>
    @ObservedObject var channels: WallpaperChannels
    let kind: WallpaperChannelKind
    let searchHint: String
    @ViewBuilder var tools: Tools
    @ViewBuilder var card: (Item) -> Card
    @State private var showChannels = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L10n.string(.WallpaperSources.gallerySearchEnabledSources(String(describing: kind.rawValue))), text: $browser.searchText)
                    .textFieldStyle(.roundedBorder).onSubmit(search)
                Button(browser.searchText.isEmpty ? L10n.string(.Common.refresh) : L10n.string(.Common.search), action: search).disabled(channels.enabled(kind).isEmpty)
                if browser.busy {
                    Button(action: browser.stop) { ArcIcon(.circleX, size: 14) }.help(L10n.string(.WallpaperSources.galleryCancelCatalogLoading)).accessibilityLabel(L10n.string(.WallpaperSources.galleryCancelCatalogLoading))
                }
                Button { showChannels = true } label: { HStack(spacing: 5) { ArcIcon(.settings, size: 13); Text(L10n.string(.WallpaperSources.channelsManageSources)) } }
                tools
            }.padding(.horizontal, 20).padding(.vertical, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.string(.WallpaperSources.galleryCombinedSources(String(describing: browser.items.count), String(describing: kind.rawValue), String(describing: channels.enabled(kind).count))))
                        Spacer()
                        if browser.busy { ProgressView().controlSize(.small); Text(L10n.string(.WallpaperSources.galleryGathering)) }
                    }.font(.caption).foregroundStyle(.secondary)
                    if browser.showingPrevious { Text(browser.busy ? L10n.string(.WallpaperSources.galleryUpdatingPreviousResultsRemainVisible) : L10n.string(.WallpaperSources.galleryRefreshIncompleteShowingPreviousResults)).font(.caption).foregroundStyle(.secondary) }
                    if !browser.query.isEmpty { Text(searchHint).font(.caption).foregroundStyle(.secondary) }
                    if let error = channels.error { Text(error + L10n.string(.WallpaperSources.galleryManageSourceSettings)).font(.caption).foregroundStyle(.orange) }
                    WallpaperChannelFailures(browser: browser)
                    LazyVGrid(columns: WallpaperGalleryLayout.columns, spacing: 16) { ForEach(browser.items) { card($0) } }
                    if browser.items.isEmpty {
                        if browser.busy || channels.busy && !channels.loaded {
                            WallpaperGalleryState(title: L10n.string(.WallpaperSources.galleryLoading(String(describing: kind.rawValue))), message: L10n.string(.WallpaperSources.galleryIndependentLoadingHint), loading: true)
                        } else if channels.enabled(kind).isEmpty {
                            WallpaperGalleryState(title: channels.loaded ? L10n.string(.WallpaperSources.gallerySourcesEnabledMissing(String(describing: kind.rawValue))) : L10n.string(.WallpaperSources.gallerySourceConfigurationNotReady), message: L10n.string(.WallpaperSources.galleryChooseWhatDisplaySourceManagement))
                            Button(L10n.string(.WallpaperSources.galleryOpenSourceManagement)) { showChannels = true }.frame(maxWidth: .infinity)
                        } else if !browser.paused.isEmpty {
                            WallpaperGalleryState(title: L10n.string(.WallpaperSources.galleryLoadingPaused), message: L10n.string(.WallpaperSources.galleryClickResumeLoadingContinueUnfinishedSources))
                        } else {
                            WallpaperGalleryState(title: L10n.string(.WallpaperSources.galleryYetMissing(String(describing: kind.rawValue))), message: browser.failures.isEmpty ? L10n.string(.WallpaperSources.galleryTryAnotherKeywordLoadNext) : L10n.string(.WallpaperSources.galleryExpandSourceErrorsRetryIndividually))
                        }
                    }
                    if browser.hasMore && !browser.busy {
                        Button(browser.paused.isEmpty ? L10n.string(.WallpaperSources.galleryLoadMore) : L10n.string(.WallpaperSources.galleryResumeLoading), action: browser.loadMore)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .task { await channels.load() }
        .task(id: channels.enabled(kind)) { browser.activate(channels: channels.enabled(kind)) }
        .sheet(isPresented: $showChannels) { WallpaperChannelsSheet(channels: channels) }
    }
    private func search() { browser.search(channels: channels.enabled(kind), query: browser.searchText) }
}
