import ArcKitPlatform
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WallpaperLibraryView: View {
    @ObservedObject var model: WallpaperModel
    let backgroundAction: WallpaperBackgroundAction
    @State private var showsImport = false
    @State private var showsLink = false
    @State private var link = ""
    @ObservedObject private var browsing: WallpaperBrowsing
    @State private var detail: WallpaperItem?
    @State private var editing: WallpaperItem?
    @State private var applying: WallpaperItem?

    let browseOnline: () -> Void

    init(model: WallpaperModel, backgroundAction: WallpaperBackgroundAction, browseOnline: @escaping () -> Void) {
        self.model = model; self.backgroundAction = backgroundAction; self.browseOnline = browseOnline
        browsing = model.browsing
    }

    private var visibleItems: [WallpaperItem] { browsing.localItems(in: model.catalog) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L10n.string(.WallpaperPlayback.displaySearchMyWallpapers), text: $browsing.localQuery).textFieldStyle(.roundedBorder)
                Picker(L10n.string(.Wallpaper.libraryFilter), selection: $browsing.localFilter) {
                    ForEach(WallpaperLibraryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 78)
                Button { showsImport = true } label: {
                    Label { Text(L10n.string(.Common.`import`)) } icon: { ArcIcon(.plus, size: 12) }
                }.disabled(model.isBusy || !model.isLoaded)
                Menu {
                    Picker(L10n.string(.Wallpaper.librarySort), selection: $browsing.localSort) {
                        ForEach(WallpaperLibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button(L10n.string(.Wallpaper.libraryDirectImageAction)) { showsLink = true }.disabled(!model.isLoaded)
                    Button(L10n.string(.Common.reload), action: model.reload)
                    Button(L10n.string(.Wallpaper.libraryOpenWallpaperFolder)) { NSWorkspace.shared.open(model.library.directory) }
                } label: { ArcIcon(.menu, size: 14) }
                    .menuStyle(.borderlessButton).frame(width: 22).disabled(model.isBusy)
                    .accessibilityLabel(L10n.string(.Wallpaper.libraryLibraryActions))
            }.padding(.horizontal, 20).padding(.vertical, 14)
            if model.catalog.items.isEmpty { emptyState }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.string(.Wallpaper.libraryCount(Int(visibleItems.count)))).font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: WallpaperGalleryLayout.columns, spacing: 16) {
                            ForEach(visibleItems) { item in
                                Button { showDetail(item) } label: {
                                    WallpaperGalleryCard(title: item.name, subtitle: item.dimensions,
                                                         badge: item.kind == .video ? L10n.string(.AppBackground.backgroundStorageVideo) : nil, favorite: item.isFavorite) {
                                        if let image = model.thumbnail(item) { Image(nsImage: image).resizable().scaledToFill() }
                                        else { ArcIcon(.image, size: 24).foregroundStyle(.tertiary) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.string(.Wallpaper.libraryViewDetails(String(describing: item.name), String(describing: item.kind == .video ? L10n.string(.AppBackground.backgroundStorageVideo) : L10n.string(.AppBackground.backgroundStorageImage)), String(describing: item.dimensions))))
                                .contextMenu {
                                    Button(L10n.string(.Wallpaper.libraryDetailsAction)) { showDetail(item) }
                                    Button(L10n.string(.WallpaperSources.motionSetDesktopWallpaper)) { applying = item }.disabled(model.isPreview || model.isBusy)
                                    Button(L10n.string(.WallpaperSources.motionSetAppBackground)) { useBackground(item) }
                                        .disabled(!backgroundAction.isAvailable)
                                    if item.kind == .video { Button(L10n.string(.Wallpaper.libraryEditLoop)) { editing = item } }
                                    Button(item.isFavorite ? L10n.string(.Wallpaper.libraryRemoveFavorites) : L10n.string(.Common.favorites)) { model.toggleFavorite(item) }.disabled(model.isBusy)
                                    Button(L10n.string(.DataManagement.dataShowFinder)) { NSWorkspace.shared.activateFileViewerSelecting([model.library.mediaURL(item)]) }
                                }
                            }
                        }
                        if visibleItems.isEmpty {
                            WallpaperGalleryState(title: L10n.string(.WallpaperPlayback.displayMatchingWallpapersMissing), message: L10n.string(.Wallpaper.libraryTryAnotherKeywordChangeFilter))
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .fileImporter(isPresented: $showsImport, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): model.importFiles(urls)
            case let .failure(error): model.showImportError(error)
            }
        }
        .sheet(isPresented: $showsLink) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string(.Wallpaper.libraryImportDirectImageLink)).font(.headline)
                TextField("https://…/image.jpg", text: $link).textFieldStyle(.roundedBorder)
                Text(L10n.string(.Wallpaper.librarySupportsHttpsUrlsReturnImagesBrowse))
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.string(.Common.cancel)) { showsLink = false }
                    Button(L10n.string(.Common.`import`)) { model.importLink(link); showsLink = false; link = "" }
                        .buttonStyle(.borderedProminent).disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 430)
        }
        .sheet(item: $detail) { item in
            WallpaperLibraryDetail(model: model, background: backgroundAction, itemID: item.id)
        }
        .sheet(item: $applying) { item in
            WallpaperApplySheet(model: model, title: item.name) { model.apply(item, request: $0) }
        }
        .sheet(item: $editing) { item in
            WallpaperLoopEditor(item: item, url: model.library.mediaURL(item)) { start, end, speed in
                model.createLoop(item, start: start, end: end, speed: speed)
            }
        }
    }

    private func showDetail(_ item: WallpaperItem) {
        model.selectedID = item.id
        detail = item
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ArcIcon(.image, size: 36).foregroundStyle(.secondary)
            Text(model.isLoaded ? L10n.string(.Wallpaper.libraryAddFirstWallpaper) : (model.hasError ? L10n.string(.Wallpaper.libraryLoadFailed) : L10n.string(.Wallpaper.libraryLoadingWallpaperLibrary))).font(.headline)
            Text(L10n.string(.Wallpaper.libraryImportImagesVideosChoose)).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.string(.Wallpaper.libraryImportFiles)) { showsImport = true }.buttonStyle(.borderedProminent).disabled(!model.isLoaded || model.isBusy)
                Button(L10n.string(.Wallpaper.libraryBrowseOnlineGallery), action: browseOnline).buttonStyle(.bordered)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func useBackground(_ item: WallpaperItem) {
        model.useBackground(item, action: backgroundAction)
    }

}

struct WallpaperLibraryDetail: View {
    @ObservedObject var model: WallpaperModel
    let background: WallpaperBackgroundAction
    let itemID: UUID
    @State private var editing = false
    @State private var removing = false
    @State private var showsApply = false
    @Environment(\.dismiss) private var dismiss

    private var item: WallpaperItem? { model.catalog.items.first { $0.id == itemID } }

    var body: some View {
        if let item {
            WallpaperDetailPanel(title: item.name, subtitle: "\(item.kind == .video ? L10n.string(.AppBackground.backgroundStorageVideo) : L10n.string(.AppBackground.backgroundStorageImage)) · \(item.dimensions) · \(L10n.fileSize(item.byteCount))") {
                Color.black.opacity(0.92).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if item.kind == .video { WallpaperVideoPreview(url: model.library.mediaURL(item)) }
                        else if let image = model.thumbnail(item) { Image(nsImage: image).resizable().scaledToFit() }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                Text(L10n.string(.WallpaperPlayback.libraryChooseOneMoreDisplaysSetting))
                    .font(.caption).foregroundStyle(.secondary)
                WallpaperApplyFeedback(model: model)
                if let origin = item.origin { WallpaperSourceAttribution(origin: origin) }
                if model.isPreview { Text(L10n.string(.Wallpaper.libraryDebugScope)).font(.caption).foregroundStyle(.secondary) }
            } actions: {
                HStack(spacing: 10) {
                    Button(item.isFavorite ? L10n.string(.Wallpaper.libraryRemoveFavorites) : L10n.string(.Common.favorites)) { model.toggleFavorite(item) }
                    Menu {
                        if item.kind == .video { Button(L10n.string(.Wallpaper.libraryEditLoopSegment)) { editing = true } }
                        Button(L10n.string(.DataManagement.dataShowFinder)) { NSWorkspace.shared.activateFileViewerSelecting([model.library.mediaURL(item)]) }
                        Button(L10n.string(.Wallpaper.libraryRemoveLibrary), role: .destructive) { removing = true }
                    } label: { ArcIcon(.menu, size: 14) }
                        .menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel(L10n.string(.Wallpaper.libraryMoreWallpaperActions))
                    Spacer(minLength: 0)
                    Button(L10n.string(.WallpaperSources.motionSetAppBackground)) {
                        model.useBackground(item, action: background)
                        dismiss()
                    }.buttonStyle(.bordered).disabled(!background.isAvailable)
                    Button(L10n.string(.WallpaperSources.motionSetDesktopWallpaper)) { showsApply = true }
                        .buttonStyle(.borderedProminent).tint(.blue).disabled(model.isPreview)
                }.disabled(model.isBusy || !model.isLoaded)
            }
            .sheet(isPresented: $showsApply) {
                WallpaperApplySheet(model: model, title: item.name) { model.apply(item, request: $0) }
            }
            .sheet(isPresented: $editing) {
                WallpaperLoopEditor(item: item, url: model.library.mediaURL(item)) { start, end, speed in
                    model.createLoop(item, start: start, end: end, speed: speed)
                }
            }
            .confirmationDialog(L10n.string(.Wallpaper.libraryRemoveAction), isPresented: $removing, titleVisibility: .visible) {
                Button(L10n.string(.Common.remove), role: .destructive) { model.remove(item); dismiss() }
            } message: { Text(L10n.string(.Wallpaper.libraryOriginalFilesCopiedMediaPreserved)) }
        }
    }

}
