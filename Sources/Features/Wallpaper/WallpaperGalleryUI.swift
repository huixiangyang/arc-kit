import ArcKitPlatform
import SwiftUI

/// 三个图库共用同一网格与媒体比例，图片的固有尺寸不能撑开网格列。
enum WallpaperGalleryLayout {
    static let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]
}

struct WallpaperThumbnail<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Color.primary.opacity(0.045)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay { content }
            .clipped()
    }
}

struct WallpaperGalleryCard<Media: View>: View {
    let title: String
    let subtitle: String
    var badge: String? = nil
    var quality: WallpaperQuality? = nil
    var favorite = false
    var downloaded = false
    @ViewBuilder var media: Media
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WallpaperThumbnail { media }
                .overlay(alignment: .topTrailing) {
                    if let quality {
                        Text(quality.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                            .padding(9)
                            .help(quality == .unknown ? L10n.string(.WallpaperMedia.galleryQualityUnknownHint) : L10n.string(.WallpaperMedia.qualityLabel(String(describing: quality.title))))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Text(badge).font(.system(size: 10, weight: .medium)).lineLimit(1).help(badge)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule()).padding(9)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if favorite { ArcIcon(.sparkles, size: 12).foregroundStyle(Color.accentColor) }
                    if downloaded { ArcIcon(.checkCircle, size: 12).foregroundStyle(.secondary).help(L10n.string(.WallpaperMedia.galleryLocalLibrary)) }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(11)
        }
        .background(.background.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovered ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
        .help(title)
    }
}

struct WallpaperRemoteImage: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else if phase.error != nil || url == nil { ArcIcon(.image, size: 24).foregroundStyle(.tertiary) }
            else { ProgressView().controlSize(.small) }
        }
    }
}

struct WallpaperGalleryState: View {
    let title: String
    let message: String
    var loading = false
    var body: some View {
        VStack(spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            else { ArcIcon(.image, size: 28).foregroundStyle(.tertiary) }
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// 详情独立于图库滚动位置。预览、属性可滚动，主要操作固定在底部。
struct WallpaperDetailPanel<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).lineLimit(2).textSelection(.enabled)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { dismiss() } label: { ArcIcon(.circleX, size: 18) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction).accessibilityLabel(L10n.string(.WallpaperMedia.galleryCloseDetails))
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions.padding(16).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 600, height: 560)
        .background(.background)
    }
}

struct WallpaperSourceAttribution: View {
    let origin: WallpaperOrigin
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(origin.author ?? origin.provider).lineLimit(1)
                Spacer()
                Link(L10n.string(.WallpaperMedia.galleryViewSource), destination: origin.pageURL)
            }.font(.caption)
            if let license = origin.license { Text(license).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
