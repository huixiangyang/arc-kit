import ArcKitPlatform
import AppKit
import SwiftUI

enum ClipboardFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .clipboard, title: L10n.string(.Clipboard.title), icon: .copy, commands: { [
            .command("section.clipboard", L10n.string(.Clipboard.title), L10n.string(.Clipboard.search), .copy,
                L10n.string(.App.searchPages), ["剪贴板", "剪切板", "复制", "历史", "clipboard", "paste", "iCloud"], .section(.clipboard), order: 25)
        ] })
    }
}

struct ClipboardView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var editor: SettingsEditor<ClipboardSettings>
    var pasteTarget: NSRunningApplication? = nil
    var compact = false
    @State private var search = ""
    @State private var favorites = false
    @State private var source: String?
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var deletingID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                filters
                Divider()
                if model.items.isEmpty { emptyState.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    HStack(spacing: 0) {
                        historyList.frame(width: max(180, min(280, geometry.size.width * 0.4)))
                            .background(ArcPalette.panelSecondary.opacity(0.22))
                        Divider()
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Divider()
                footer.padding(.horizontal, 14).padding(.vertical, 9)
            }
        }.appBackgroundSurface()
            .sheet(isPresented: $showsSettings) { ClipboardPreferencesView(editor: editor, model: model) }
            .alert(L10n.string(.Clipboard.clearLocal), isPresented: $confirmsClear) {
                Button(L10n.string(.Common.cancel), role: .cancel) {}
                Button(L10n.string(.Clipboard.clearLocal), role: .destructive) { model.clearLocal() }
            } message: { Text(L10n.string(model.cloudConfigured ? .Clipboard.clearLocalHint : .Clipboard.clearLocalOnlyHint)) }
            .alert(L10n.string(.Clipboard.delete), isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
                Button(L10n.string(.Common.cancel), role: .cancel) { deletingID = nil }
                Button(L10n.string(.Clipboard.delete), role: .destructive) { if let id = deletingID { model.delete(id) }; deletingID = nil }
            } message: { Text(L10n.string(model.cloudConfigured ? .Clipboard.deleteHint : .Clipboard.deleteLocalOnlyHint)) }
            .onAppear { search = model.search; favorites = model.favoritesOnly; source = model.sourceFilter; model.reload(); if compact { searchFocused = true } }
            .onChange(of: search) { model.search = $0; model.reload() }
            .onChange(of: favorites) { model.favoritesOnly = $0; model.reload() }
            .onChange(of: source) { model.sourceFilter = $0; model.reload() }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down, !model.items.isEmpty else { return }
                let current = model.items.firstIndex(where: { $0.id == model.selectedItem?.id }) ?? 0
                let next = min(model.items.count - 1, max(0, current + (direction == .down ? 1 : -1)))
                model.select(model.items[next].id)
            }
            .onExitCommand { if compact { model.closeHistory?() } }
    }

    // 页面名称由侧栏与窗口标题提供，内容区直接呈现搜索和操作。
    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                ArcIcon(.search, size: 14).foregroundStyle(.secondary)
                TextField(L10n.string(.Clipboard.search), text: $search).textFieldStyle(.plain).focused($searchFocused)
                    .font(.system(size: 13))
                    .onSubmit {
                        if compact, pasteTarget != nil { model.pasteSelected(target: pasteTarget) }
                        else { model.copySelected() }
                    }
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .background(ArcPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ArcPalette.panelBorder.opacity(0.35), lineWidth: 0.5))
            Toggle(L10n.string(.Clipboard.record), isOn: Binding(get: { editor.settings.isEnabled }, set: { enabled in
                editor.update { $0.isEnabled = enabled }
            })).toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).fixedSize()
            iconButton(.Clipboard.preferences, icon: .settings) { showsSettings = true }
        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker(L10n.string(.Clipboard.filter), selection: $favorites) {
                Text(L10n.string(.Clipboard.history)).tag(false)
                Text(L10n.string(.Clipboard.favorites)).tag(true)
            }.labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
            Spacer(minLength: 4)
            Menu {
                Button(L10n.string(.Clipboard.allSources)) { source = nil }
                ForEach(model.sources) { entry in
                    Button(entry.name.isEmpty ? L10n.string(.Clipboard.unknownSource) : entry.name) { source = entry.id }
                }
            } label: {
                Text(source == nil ? L10n.string(.Clipboard.allSources) : (model.sources.first(where: { $0.id == source })?.name ?? source!)).lineLimit(1)
            }.menuStyle(.borderlessButton).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 150, alignment: .trailing)
        }.padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.items) { item in
                        Button { model.select(item.id) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                ArcIcon(item.kind == .image ? .image : (item.kind == .link ? .arrowUpRight : .fileText), size: 15)
                                    .foregroundStyle(.secondary).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.kind == .image ? L10n.string(.Clipboard.image) : item.preview)
                                        .font(.system(size: 13)).lineLimit(2)
                                    HStack(spacing: 5) {
                                        Text(item.sourceName.isEmpty ? L10n.string(.Clipboard.unknownSource) : item.sourceName).lineLimit(1)
                                        if item.favorite { ArcIcon(.archive, size: 10).accessibilityLabel(L10n.string(.Clipboard.favorite)) }
                                        Spacer(minLength: 2)
                                        Text(item.createdAt, style: .time).monospacedDigit()
                                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 9).padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .background(model.selectedItem?.id == item.id ? ArcPalette.sidebarActive : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                        .id(item.id)
                        .contextMenu {
                            Button(L10n.string(item.favorite ? .Clipboard.unfavorite : .Clipboard.favorite)) { model.favorite(item.id, value: !item.favorite) }
                            Button(L10n.string(.Clipboard.delete), role: .destructive) { deletingID = item.id }
                        }
                    }
                }.padding(6)
            }
            .onChange(of: model.selectedItem?.id) { id in if let id { proxy.scrollTo(id) } }
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = model.selectedItem, let content = item.content {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(content.kind == .image ? L10n.string(.Clipboard.image) : (content.kind == .link ? L10n.string(.Clipboard.link) : L10n.string(.Clipboard.text)))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    iconButton(item.favorite ? .Clipboard.unfavorite : .Clipboard.favorite, icon: .archive) { model.favorite(item.id, value: !item.favorite) }
                        .foregroundStyle(item.favorite ? ArcPalette.orange : .secondary)
                    iconButton(.Clipboard.delete, icon: .trash2) { deletingID = item.id }
                }
                Group {
                    if let png = content.png, let image = NSImage(data: png) {
                        GeometryReader { geometry in
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .accessibilityLabel(L10n.string(.Clipboard.image))
                        }
                    } else {
                        ScrollView {
                            Text(content.text ?? "").font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.deviceName).lineLimit(1)
                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack { primaryAction; moreActions }
                    VStack(alignment: .leading) { primaryAction; moreActions }
                }
            }.padding(16)
        }
    }

    private var primaryAction: some View {
        Button { model.copySelected() } label: {
            HStack(spacing: 6) { ArcIcon(.copy, size: 14); Text(L10n.string(.Clipboard.copy)) }
        }.buttonStyle(.borderedProminent)
    }
    private var moreActions: some View {
        Menu(L10n.string(.Clipboard.actions)) {
            if compact {
                Button(L10n.string(.Clipboard.paste)) { model.pasteSelected(target: pasteTarget) }.disabled(pasteTarget == nil)
                if model.selectedItem?.content?.kind != .image {
                    Button(L10n.string(.Clipboard.pastePlain)) { model.pasteSelected(plain: true, target: pasteTarget) }.disabled(pasteTarget == nil)
                }
            }
            if model.selectedItem?.content?.kind != .image {
                Button(L10n.string(.Clipboard.copyPlain)) { model.copySelected(plain: true) }
            }
            Divider()
            Button(L10n.string(.Clipboard.saveFinder)) { model.saveSelectedToFinder() }
            if model.selectedItem?.content?.kind != .image {
                Button(L10n.string(.Clipboard.saveMarkdown)) { model.saveSelectedToFinder(markdown: true) }
            }
            Button(L10n.string(.Clipboard.saveAs)) { model.saveSelectedAs() }
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = editor.failureMessage ?? model.message ?? model.shortcutError {
                HStack(alignment: .top, spacing: 8) {
                    ArcIcon(.circleInfo, size: 14).foregroundStyle(ArcPalette.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.message != nil { iconButton(.Clipboard.dismiss, icon: .circleX) { model.clearMessage() } }
                }
            }
            HStack(spacing: 7) {
                ArcIcon(model.cloudConfigured && model.settings.syncEnabled ? .cloudDownload : .hardDrive, size: 13)
                Text(!model.cloudConfigured || !model.settings.syncEnabled ? L10n.string(.Clipboard.localOnly) : model.syncStatus.text).lineLimit(2)
                Spacer()
                Text("\(model.items.count)").monospacedDigit()
                Button(L10n.string(.Clipboard.clearLocal)) { confirmsClear = true }.buttonStyle(.borderless).disabled(model.items.isEmpty || model.busy)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if !search.isEmpty || favorites || source != nil {
                Text(L10n.string(.Clipboard.noMatches)).foregroundStyle(.secondary)
                Button(L10n.string(.Clipboard.resetFilters)) { search = ""; favorites = false; source = nil }
            } else if !model.settings.isEnabled {
                Button(L10n.string(.Clipboard.startRecording)) { editor.update { $0.isEnabled = true } }
            } else {
                Text(L10n.string(.Clipboard.empty)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13)).padding(24)
    }

    private func iconButton(_ title: LocalizedStringResource, icon: ArcIconName, action: @escaping () -> Void) -> some View {
        Button(action: action) { ArcIcon(icon, size: 15).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(L10n.string(title)).accessibilityLabel(L10n.string(title))
    }
}

struct ClipboardPreferencesView: View {
    @ObservedObject var editor: SettingsEditor<ClipboardSettings>
    @ObservedObject var model: ClipboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var excluded = ""
    @State private var confirmsConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.string(.Clipboard.preferences)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L10n.string(.Common.close)) { Task { if await editor.commitPendingChanges() { dismiss() } } }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                preferencesContent
            }
        }.padding(24).frame(width: 558, height: 690)
            .alert(L10n.string(.Clipboard.connect), isPresented: $confirmsConnection) {
                Button(L10n.string(.Common.cancel), role: .cancel) {}
                Button(L10n.string(.Clipboard.connect)) { Task { if await editor.commitPendingChanges() { model.synchronize(approve: true) } } }
            } message: { Text(L10n.string(.Clipboard.connectConsent)) }
            .onDisappear { model.shortcutRecording(false) }
    }

    private var preferencesContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.string(.Clipboard.shortcut))
                Spacer()
                KeyboardShortcutRecorder(binding: Binding(get: { editor.settings.shortcut }, set: { chord in editor.update { $0.shortcut = chord } }),
                    duplicateShortcuts: [], rejectDuplicates: true, onRecordingChange: { _, active in model.shortcutRecording(active) })
                    .frame(width: 200, height: 30)
                Button { editor.update { $0.shortcut = .disabled } } label: { ArcIcon(.circleX, size: 14) }
                    .buttonStyle(.borderless).help(L10n.string(.Common.shortcutRecorderDisable))
            }
            HStack {
                Text(L10n.string(.Clipboard.retention))
                Spacer()
                Picker(L10n.string(.Clipboard.retention), selection: Binding(get: { editor.settings.retentionDays }, set: { days in editor.update { $0.retentionDays = days } })) {
                    Text(L10n.string(.Clipboard.oneDay)).tag(1)
                    Text(L10n.string(.Clipboard.sevenDays)).tag(7)
                    Text(L10n.string(.Clipboard.thirtyDays)).tag(30)
                }.labelsHidden().frame(width: 150)
            }
            Text(L10n.string(model.cloudConfigured ? .Clipboard.retentionHint : .Clipboard.retentionLocalOnlyHint)).font(.system(size: 12)).foregroundStyle(.secondary)
            // 本地发行隐藏尚未开放的云端操作，不留下不可用的设置入口。
            if model.cloudConfigured {
                Divider()
                Toggle(L10n.string(.Clipboard.syncEnable), isOn: Binding(get: { editor.settings.syncEnabled }, set: { enabled in editor.update { $0.syncEnabled = enabled } }))
                    .toggleStyle(.switch).controlSize(.small)
                Text(model.syncStatus.text)
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L10n.string(.Clipboard.uploadScope), selection: Binding(get: { editor.settings.syncScope }, set: { scope in editor.update { $0.syncScope = scope } })) {
                    Text(L10n.string(.Clipboard.favoritesOnly)).tag(ClipboardSyncScope.favorites)
                    Text(L10n.string(.Clipboard.allHistory)).tag(ClipboardSyncScope.history)
                }.disabled(!editor.settings.syncEnabled)
                Text(L10n.string(.Clipboard.scopeHint)).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string(.Clipboard.connect)) { confirmsConnection = true }.disabled(!editor.settings.syncEnabled)
                    Button(L10n.string(.Clipboard.syncNow)) { Task { if await editor.commitPendingChanges() { model.synchronize() } } }.disabled(!editor.settings.syncEnabled)
                }
            }
            Divider()
            Text(L10n.string(.Clipboard.exclusions)).font(.system(size: 13, weight: .semibold))
            HStack {
                TextField(L10n.string(.Clipboard.bundleID), text: $excluded)
                Button(L10n.string(.Clipboard.add)) {
                    let id = excluded.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return }
                    editor.update { $0.excludedApplications.insert(id) }; excluded = ""
                }.disabled(excluded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(editor.settings.excludedApplications.sorted(), id: \.self) { id in
                        HStack {
                            Text(id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button { editor.update { $0.excludedApplications.remove(id) } } label: { ArcIcon(.circleX, size: 13) }
                                .buttonStyle(.borderless).accessibilityLabel(L10n.string(.Clipboard.remove))
                        }
                    }
                }
            }.frame(maxHeight: 130)
            Text(L10n.string(.Clipboard.privacyHint)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = editor.failureMessage ?? model.shortcutError { Text(error).font(.system(size: 12)).foregroundStyle(ArcPalette.red) }
        }.padding(.trailing, 8)
    }
}

@MainActor
final class ClipboardPanelController {
    private var panel: NSPanel?
    func show(model: ClipboardModel, editor: SettingsEditor<ClipboardSettings>) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        let target = NSWorkspace.shared.frontmostApplication
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.string(.Clipboard.title)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.minSize = NSSize(width: 600, height: 460)
        panel.contentView = NSHostingView(rootView: ClipboardView(model: model, editor: editor, pasteTarget: target, compact: true))
        panel.center(); self.panel = panel
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    func close() { panel?.orderOut(nil) }
}
