import ArcKitPlatform
import SwiftUI

struct WallpaperChannelsSheet: View {
    @ObservedObject var channels: WallpaperChannels
    @State private var address = ""
    @State private var inputError: String?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(.WallpaperSources.channelsManageSources)).font(.headline)
                    Text(L10n.string(.WallpaperSources.channelsImagesVideosCombinedTheir))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { ArcIcon(.circleX, size: 18) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction).accessibilityLabel(L10n.string(.WallpaperSources.channelsCloseSourceManagement))
                    .disabled(adding)
            }.padding(20)
            Divider()
            Form {
                if let error = channels.error {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        if !channels.loaded {
                            Button(L10n.string(.WallpaperSources.channelsReloadConfiguration)) { Task { await channels.load() } }.disabled(channels.busy)
                        }
                    }
                }
                ForEach(WallpaperChannelKind.allCases, id: \.self) { kind in
                    Section {
                        ForEach(WallpaperChannel.builtins.filter { $0.kind == kind }) { channel in
                            channelRow(channel)
                        }
                    } header: {
                        Text(L10n.string(.WallpaperSources.channelsBuiltSources(String(describing: kind.title))))
                    }
                }
                Section {
                    ForEach(channels.feeds) { feed in
                        HStack(spacing: 12) {
                            channelRow(WallpaperChannel(source: .feed(feed)))
                            Button { Task { await channels.remove(feed) } } label: { ArcIcon(.trash2, size: 14) }
                                .buttonStyle(.borderless).help(L10n.string(.WallpaperSources.channelsRemoveFeedKeepDownloadedWallpapers))
                                .accessibilityLabel(L10n.string(.WallpaperSources.channelsRemove(String(describing: feed.name)))).disabled(channels.busy)
                        }
                    }
                    if channels.feeds.isEmpty {
                        Text(L10n.string(.WallpaperSources.channelsFeedsYetAddVideoCatalogMissing)).font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.string(.WallpaperSources.channelsCustomVideoSources)) }
            }.formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("https://…/wallpapers.json", text: $address).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.string(.WallpaperSources.channelsVideoFeedUrl)).onSubmit(addSubscription)
                    if adding { ProgressView().controlSize(.small) }
                    Button(L10n.string(.WallpaperSources.channelsAddVideoFeed), action: addSubscription)
                        .disabled(channels.busy || !channels.loaded || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let inputError { Text(inputError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Text(L10n.string(.WallpaperSources.channelsSupportsHttpsJsonCatalogsArcKit))
                Text(L10n.string(.WallpaperSources.channelsLibraryUnaffectedHint))
            }.font(.caption).foregroundStyle(.secondary).padding(16)

        }
        .frame(width: 600, height: 660).background(.background)
        .task { await channels.load() }
        .interactiveDismissDisabled(adding)
    }
    private func channelRow(_ channel: WallpaperChannel) -> some View {
        Toggle(isOn: Binding(get: { channels.isEnabled(channel) }, set: { enabled in
            Task { await channels.setEnabled(channel, enabled) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name).lineLimit(1)
                Text(channel.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(channel.detail)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small).disabled(channels.busy || !channels.loaded)
    }
    private func addSubscription() {
        guard !channels.busy, channels.loaded, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        adding = true; inputError = nil
        Task {
            defer { adding = false }
            do { try await channels.subscribe(address); address = "" }
            catch { inputError = error.localizedDescription }
        }
    }
}

/// 错误按渠道呈现，不遮住已经成功加载的图库。
struct WallpaperChannelFailures<Item: Identifiable & Sendable>: View where Item.ID: Sendable {
    @ObservedObject var browser: WallpaperMixedBrowser<Item>
    @State private var expanded = false
    var body: some View {
        if !browser.failures.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if browser.failures.count > 1 { Button(L10n.string(.WallpaperSources.channelsRetryAllSourcesFailed), action: browser.retryFailures).disabled(browser.busy) }
                    ForEach(browser.channels.filter { browser.failures[$0.id] != nil }) { channel in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channel.name).fontWeight(.medium)
                                Text(browser.failures[channel.id] ?? "").foregroundStyle(.secondary)
                                    .lineLimit(2).textSelection(.enabled).help(browser.failures[channel.id] ?? "")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.string(.Common.retry)) { browser.retry(channel.id) }.disabled(browser.busy)
                        }
                    }
                }.padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    ArcIcon(.triangleAlert, size: 13).foregroundStyle(.orange)
                    Text(L10n.string(.WallpaperSources.sourcesFailedCount(Int(browser.failures.count)))).foregroundStyle(.secondary)
                }
            }.font(.caption).padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
