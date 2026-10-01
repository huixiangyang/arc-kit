import ArcKitPlatform
import SwiftUI

/// 以系统桌面坐标绘制屏幕位置；只读排列，点击用于选择目标，不移动系统显示器。
struct WallpaperDisplayMap: View {
    let displays: [WallpaperDisplay]
    let selected: Set<String>
    let select: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            let bounds = displays.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = min((proxy.size.width - 24) / max(bounds.width, 1), (proxy.size.height - 24) / max(bounds.height, 1))
            ZStack {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    displayButton(display, number: index + 1)
                        .frame(width: max(1, display.frame.width * scale - 4), height: max(1, display.frame.height * scale - 4))
                        .position(x: (proxy.size.width - bounds.width * scale) / 2 + (display.frame.midX - bounds.minX) * scale,
                                  y: (proxy.size.height - bounds.height * scale) / 2 + (bounds.maxY - display.frame.midY) * scale)
                }
            }
        }.frame(height: 142)
    }

    private func displayButton(_ display: WallpaperDisplay, number: Int) -> some View {
        Button { select(display.id) } label: {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected.contains(display.id) ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045))
                if display.isPrimary {
                    Capsule().fill(Color.primary.opacity(0.5)).frame(height: 3).padding(7)
                }
                Text("\(number)").font(.system(size: 20, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected.contains(display.id) ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected.contains(display.id) ? 2 : 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(.WallpaperPlayback.displayDisplay(String(describing: number), String(describing: display.name), String(describing: display.isPrimary ? L10n.string(.WallpaperPlayback.displayMainDisplay) : ""))))
        .accessibilityAddTraits(selected.contains(display.id) ? .isSelected : [])
    }
}

/// 所有图库共用显式选屏流程；多屏默认不勾选，避免一次点击替换全部桌面。
struct WallpaperApplySheet: View {
    @ObservedObject var model: WallpaperModel
    let title: String
    let apply: (WallpaperDesktopRequest) -> UUID?
    @State private var selected: Set<String> = []
    @State private var scaling: WallpaperScaling = .fill
    @State private var submitted: UUID?
    @Environment(\.dismiss) private var dismiss

    private var connected: Set<String> { Set(model.displays.map(\.id)) }
    private var missing: Set<String> { selected.subtracting(connected) }

    var body: some View {
        WallpaperDetailPanel(title: L10n.string(.WallpaperPlayback.displaySetDesktopWallpaper), subtitle: title) {
            HStack {
                Text(L10n.string(.WallpaperPlayback.displayChooseDisplays)).font(.headline)
                Spacer()
                Button(L10n.string(.App.menuSelectAll)) { selected = connected }.disabled(model.isBusy || connected.isEmpty)
                Button(L10n.string(.WallpaperPlayback.displayClear)) { selected.removeAll() }.disabled(model.isBusy || selected.isEmpty)
            }
            if model.displays.isEmpty {
                Text(L10n.string(.WallpaperPlayback.displayNoneAvailable)).foregroundStyle(.secondary)
            } else {
                WallpaperDisplayMap(displays: model.displays, selected: selected, select: toggle)
                VStack(spacing: 12) {
                    ForEach(model.displays) { display in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(isOn: Binding(get: { selected.contains(display.id) }, set: { _ in toggle(display.id) })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayTitle(display))
                                    Text("\(display.width) × \(display.height) · \(model.assignedItem(on: display.id)?.name ?? L10n.string(.WallpaperPlayback.displayUsingSystemWallpaper))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.toggleStyle(.checkbox).disabled(model.isBusy)
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(missing.sorted(), id: \.self) { id in
                        Toggle(L10n.string(.WallpaperPlayback.displaySelectedDisplayDisconnectedDeselectContinue), isOn: Binding(get: { selected.contains(id) }, set: { _ in toggle(id) }))
                            .toggleStyle(.checkbox).foregroundStyle(.orange)
                    }
                }
            }
            Divider()
            Picker(L10n.string(.WallpaperPlayback.displayScaling), selection: $scaling) {
                ForEach(WallpaperScaling.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.isBusy)
            Text(L10n.string(.WallpaperPlayback.displayAppliesSelectedDisplaysMirroredDisplays))
                .font(.caption).foregroundStyle(.secondary)
            if model.catalog.preferences.rotationEnabled,
               model.catalog.preferences.displayID == "all" || selected.contains(model.catalog.preferences.displayID) {
                Text(L10n.string(.WallpaperPlayback.displayRotationStillEnabledSelected))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if submitted != nil { WallpaperApplyFeedback(model: model) }
        } actions: {
            HStack {
                Text(selected.isEmpty ? L10n.string(.WallpaperPlayback.displaySelectLeastOneDisplay) : L10n.string(.WallpaperPlayback.displaysSelectedCount(Int(selected.count))))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy && model.canCancelOperation { Button(L10n.string(.WallpaperPlayback.displayCancelOperation), action: model.cancelOperation) }
                Button(L10n.string(.WallpaperPlayback.displayApplyWallpaper)) {
                    submitted = apply(WallpaperDesktopRequest(displayIDs: selected, scaling: scaling))
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || !missing.isEmpty || model.isBusy || !model.isLoaded || model.isPreview)
            }
        }
        .onAppear {
            model.refreshDisplays()
            if model.displays.count == 1 { selected = connected }
        }
        .onChange(of: model.isBusy) { busy in
            if submitted != nil && submitted == model.operationID && !busy && model.feedback?.kind == .success { dismiss() }
        }
        // 下载期间禁止变更本次请求；运行中的任务持有独立目标快照。
        .interactiveDismissDisabled(model.isBusy)
    }

    private func toggle(_ id: String) {
        guard !model.isBusy else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

struct WallpaperApplyFeedback: View {
    @ObservedObject var model: WallpaperModel
    var body: some View {
        if model.isBusy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.operationProgress ?? L10n.string(.WallpaperPlayback.displayApplyingWallpaper)).font(.caption) }
        } else if let feedback = model.feedback {
            Text(feedback.message).font(.caption).foregroundStyle(model.hasError ? Color.orange : Color.secondary).textSelection(.enabled)
        }
    }
}

struct WallpaperDisplaysSettings: View {
    @ObservedObject var model: WallpaperModel
    @State private var editing: WallpaperDisplay?
    private var disconnected: [String] { model.catalog.assignments.keys.filter { id in !model.displays.contains { $0.id == id } }.sorted() }

    var body: some View {
        Section {
            if !model.displays.isEmpty {
                WallpaperDisplayMap(displays: model.displays, selected: [], select: { id in editing = model.displays.first { $0.id == id } })
                ForEach(model.displays) { display in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            thumbnail(display).frame(width: 76, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayTitle(display)).fontWeight(.medium)
                                Text("\(display.width) × \(display.height)").font(.caption).foregroundStyle(.secondary)
                                Text(status(display)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.string(.WallpaperPlayback.displayChange)) { editing = display }
                        }
                        if let item = model.assignedItem(on: display.id), let assignment = model.catalog.assignments[display.id] {
                            Picker(L10n.string(.WallpaperPlayback.displayScalingDisplay), selection: Binding(get: { assignment.scaling }, set: { value in
                                model.apply(item, request: WallpaperDesktopRequest(displayIDs: [display.id], scaling: value))
                            })) {
                                ForEach(WallpaperScaling.allCases) { Text($0.title).tag($0) }
                            }.disabled(model.isPreview)
                        }
                    }.padding(.vertical, 6)
                }
            } else { Text(L10n.string(.WallpaperPlayback.displayAvailableDisplaysMissing)).foregroundStyle(.secondary) }
            HStack {
                Text(L10n.string(.WallpaperPlayback.displayEachDisplayDifferentWallpaper))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string(.Common.refresh), action: model.refreshDisplays)
            }
        } header: { Text(L10n.string(.WallpaperPlayback.displayDisplaysWallpapers)) }
        .sheet(item: $editing) { WallpaperScreenEditor(model: model, display: $0) }
        if !disconnected.isEmpty {
            Section(L10n.string(.WallpaperPlayback.displayDisconnectedDisplays)) {
                ForEach(Array(disconnected.enumerated()), id: \.element) { index, id in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string(.WallpaperPlayback.displayDisconnectedDisplay(String(describing: index + 1))))
                            Text(model.assignedItem(on: id)?.name ?? L10n.string(.WallpaperPlayback.displayWallpaperUnavailable)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.string(.WallpaperPlayback.displayRemoveConfiguration)) { model.forgetDisconnectedDisplay(id) }
                    }
                }
                Text(L10n.string(.WallpaperPlayback.displayKeepsConfigurationRestoreVideoWallpaper))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func thumbnail(_ display: WallpaperDisplay) -> some View {
        Color.primary.opacity(0.06).overlay {
            if let item = model.assignedItem(on: display.id), let image = model.thumbnail(item) {
                Image(nsImage: image).resizable().scaledToFill()
            } else { ArcIcon(.monitor, size: 22).foregroundStyle(.secondary) }
        }.clipped()
    }

    private func status(_ display: WallpaperDisplay) -> String {
        guard let item = model.assignedItem(on: display.id) else { return L10n.string(.WallpaperPlayback.displayUsingSystemWallpaper) }
        let state = model.appliedDisplayIDs.contains(display.id) ? (item.kind == .video && model.videoPaused ? L10n.string(.Common.paused) : L10n.string(.WallpaperPlayback.displayUse)) : L10n.string(.WallpaperPlayback.displayUnconfirmedAssignment)
        return "\(state) · \(item.name)"
    }
}

struct WallpaperScreenEditor: View {
    @ObservedObject var model: WallpaperModel
    let display: WallpaperDisplay
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var scaling: WallpaperScaling = .fill
    @State private var submitted: UUID?
    @Environment(\.dismiss) private var dismiss

    private var connected: Bool { model.displays.contains { $0.id == display.id } }
    private var items: [WallpaperItem] { model.catalog.items.reversed().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        WallpaperDetailPanel(title: L10n.string(.WallpaperPlayback.displayChooseWallpaperDisplay), subtitle: model.displayTitle(display)) {
            if !connected { Text(L10n.string(.WallpaperPlayback.displayDisplayDisconnectedReconnect)).foregroundStyle(.orange) }
            if model.catalog.preferences.rotationEnabled,
               model.catalog.preferences.displayID == "all" || model.catalog.preferences.displayID == display.id {
                Text(L10n.string(.WallpaperPlayback.displayDisplayAutomaticRotationEnabledApplying)).font(.caption).foregroundStyle(.secondary)
            }
            TextField(L10n.string(.WallpaperPlayback.displaySearchMyWallpapers), text: $query).textFieldStyle(.roundedBorder)
            if model.catalog.items.isEmpty {
                WallpaperGalleryState(title: L10n.string(.WallpaperPlayback.displayWallpapersYetMissing), message: L10n.string(.WallpaperPlayback.displayImportFilesMyWallpapersDownload))
            } else {
                LazyVGrid(columns: WallpaperGalleryLayout.columns, spacing: 16) {
                    ForEach(items) { item in
                        Button { selectedID = item.id } label: {
                            WallpaperGalleryCard(title: item.name, subtitle: item.dimensions, badge: item.kind == .video ? L10n.string(.AppBackground.backgroundStorageVideo) : nil) {
                                if let image = model.thumbnail(item) { Image(nsImage: image).resizable().scaledToFill() }
                                else { ArcIcon(.image, size: 22) }
                            }
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selectedID == item.id ? Color.accentColor : .clear, lineWidth: 2) }
                        }.buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                    }
                }
                if items.isEmpty { Text(L10n.string(.WallpaperPlayback.displayMatchingWallpapersMissing)).foregroundStyle(.secondary) }
            }
            if submitted != nil { WallpaperApplyFeedback(model: model) }
        } actions: {
            HStack {
                Picker(L10n.string(.WallpaperPlayback.displayScaling), selection: $scaling) {
                    ForEach(WallpaperScaling.allCases) { Text($0.title).tag($0) }
                }.frame(width: 220).disabled(model.isBusy)
                Spacer()
                Button(L10n.string(.WallpaperPlayback.displayApplyDisplay)) {
                    guard let item = model.catalog.items.first(where: { $0.id == selectedID }) else { return }
                    submitted = model.apply(item, request: WallpaperDesktopRequest(displayIDs: [display.id], scaling: scaling))
                }.buttonStyle(.borderedProminent)
                    .disabled(!connected || selectedID == nil || model.isBusy || !model.isLoaded || model.isPreview)
            }
        }
        .onAppear {
            model.refreshDisplays()
            if let assignment = model.catalog.assignments[display.id] { selectedID = assignment.itemID; scaling = assignment.scaling }
        }
        .onChange(of: model.isBusy) { busy in if submitted != nil && submitted == model.operationID && !busy && model.feedback?.kind == .success { dismiss() } }
    }
}
