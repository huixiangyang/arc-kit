import ArcKitPlatform
import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarShelfModel: ObservableObject {
    var supportsCollectedScope = true
    @Published var scope: MenuBarShelfScope = .all { didSet { selectFirstIfNeeded() } }
    @Published private(set) var partition: MenuBarPartitionSnapshot?
    @Published var feedback: String?
    @Published var query = "" { didSet { selectFirstIfNeeded() } }
    @Published private(set) var items: [MenuBarObservedItem] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var scrollTarget: UUID?
    @Published private(set) var permissionRequired = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var issueCount = 0
    @Published private(set) var inventoryID: UUID?
    var onActivate: ((UUID, UUID) -> Void)?

    var filteredItems: [MenuBarObservedItem] {
        guard scope != .collected || supportsCollectedScope else { return [] }
        let terms = normalized(query).split(whereSeparator: \.isWhitespace)
        return items.filter { scope == .all || partition?.section(of: $0) == .collected }.filter { item in
            let text = normalized([item.displayTitle, item.applicationName, item.label ?? "", item.bundleIdentifier ?? ""].joined(separator: " "))
            return terms.allSatisfy { text.contains($0) }
        }
    }
    var scopeError: String? {
        if scope == .collected && !supportsCollectedScope { return L10n.string(.MenuBar.overflowSectionsUnavailable) }
        guard scope == .collected, !isLoading, inventoryID != nil, partition == nil else { return nil }
        return L10n.string(.MenuBar.scopeUnavailable)
    }
    var unclassifiedCount: Int {
        guard scope == .collected, let partition else { return 0 }
        return items.filter { partition.section(of: $0) == .unknown }.count
    }
    var preferredHeight: CGFloat {
        if error != nil || scopeError != nil { return 400 }
        if isLoading || filteredItems.isEmpty { return 280 }
        return min(400, 156 + CGFloat(min(filteredItems.count, 5)) * 52 + (feedback == nil ? 0 : 64))
    }

    func begin(clearQuery: Bool) {
        partition = nil
        items = []; selectedID = nil; scrollTarget = nil; inventoryID = nil; error = nil; permissionRequired = false; issueCount = 0; isLoading = true
        if clearQuery { query = ""; feedback = nil }
    }
    func load(_ inventory: MenuBarInventory, partition: MenuBarPartitionSnapshot? = nil, targetDisplayID: UInt32? = nil) {
        isLoading = false
        inventoryID = inventory.id
        issueCount = inventory.issues.count
        guard inventory.accessibility == .granted else { fail(L10n.string(.MenuBar.settingsMainPermission), permissionRequired: true); return }
        guard inventory.canUseGeometry else { fail(L10n.string(.MenuBar.accessDisplayChanged)); return }
        self.partition = partition.flatMap {
            $0.displays == inventory.displays && (targetDisplayID == nil || $0.displayID == targetDisplayID) ? $0 : nil
        }
        items = inventory.items.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.sorted {
            let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            return order == .orderedSame ? ($0.accessibilityIdentifier ?? "") < ($1.accessibilityIdentifier ?? "") : order == .orderedAscending
        }
        selectFirstIfNeeded()
    }
    func fail(_ detail: String, permissionRequired: Bool = false) {
        isLoading = false; error = detail; feedback = nil; self.permissionRequired = permissionRequired
        inventoryID = nil; items = []; selectedID = nil; scrollTarget = nil; partition = nil
    }
    func clear() { begin(clearQuery: true); isLoading = false }
    func select(_ id: UUID) { selectedID = id }
    func move(by delta: Int) {
        let available = filteredItems.filter(\.supportsActivation)
        guard !available.isEmpty else { selectedID = nil; return }
        let index = available.firstIndex { $0.id == selectedID } ?? 0
        selectedID = available[max(0, min(available.count - 1, index + delta))].id
        scrollTarget = selectedID
    }
    func activate(_ id: UUID? = nil) {
        guard !isLoading, let inventoryID, let id = id ?? selectedID,
              filteredItems.contains(where: { $0.id == id && $0.supportsActivation }) else { return }
        onActivate?(id, inventoryID)
    }
    private func selectFirstIfNeeded() {
        if !filteredItems.contains(where: { $0.id == selectedID && $0.supportsActivation }) {
            selectedID = filteredItems.first(where: \.supportsActivation)?.id
            scrollTarget = selectedID
        }
    }
    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: L10n.locale)
    }
}

struct MenuBarShelfView: View {
    @ObservedObject var model: MenuBarShelfModel
    let refresh: () -> Void
    let close: () -> Void
    var openPermission: (() -> Void)? = nil
    var showAll: (() -> Void)? = nil
    var isPreview = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArcIcon(.search, size: 17).foregroundStyle(ArcPalette.orange)
                TextField(L10n.string(.MenuBar.shelfSearch), text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($searchFocused)
                    .onSubmit { model.activate() }
                Button(action: refresh) { ArcIcon(.refreshCw, size: 15) }
                    .buttonStyle(.plain).disabled(model.isLoading).accessibilityLabel(L10n.string(.MenuBar.inventoryRefresh))
                Button(action: close) { ArcIcon(.circleX, size: 15) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string(.Common.close))
            }.padding(18)
            Divider()
            if let feedback = model.feedback {
                HStack(alignment: .top, spacing: 8) {
                    ArcIcon(.triangleAlert, size: 14).foregroundStyle(ArcPalette.orange)
                    Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 18).padding(.top, 12)
            }
            HStack {
                if isPreview { Text(L10n.string(.MenuBar.shelfPreview)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                if model.supportsCollectedScope {
                    Picker(L10n.string(.MenuBar.scopeLabel), selection: $model.scope) {
                        ForEach(MenuBarShelfScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                } else {
                    Text(L10n.string(.MenuBar.scopeAll)).font(.system(size: 12, weight: .medium))
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                else if model.error != nil || model.scopeError != nil { Text("—").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityLabel(L10n.string(.MenuBar.scopeCountUnknown)) }
                else { Text(String(model.filteredItems.count)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            if let error = model.error ?? model.scopeError {
                VStack(spacing: 10) {
                    ArcIcon(.triangleAlert, size: 24).foregroundStyle(ArcPalette.orange)
                    Text(error).font(.system(size: 13)).multilineTextAlignment(.center)
                    if model.permissionRequired, let openPermission {
                        Button(L10n.string(.MenuBar.settingsOpenPermission), action: openPermission)
                    }
                    if model.scopeError != nil, let showAll {
                        Button(L10n.string(.MenuBar.actionShowAll), action: showAll)
                    }
                    Button(L10n.string(.MenuBar.inventoryRefresh), action: refresh)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    ArcIcon(model.isLoading ? .search : .archive, size: 26).foregroundStyle(.secondary)
                    Text(L10n.string(model.isLoading ? .MenuBar.shelfLoading : .MenuBar.shelfEmpty)).font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.filteredItems) { item in tile(item).id(item.id) }
                        }.padding(.horizontal, 12).padding(.bottom, 12)
                    }.onChange(of: model.scrollTarget) { id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                ArcIcon(model.issueCount > 0 || model.unclassifiedCount > 0 ? .circleInfo : .cornerDownLeft, size: 13).foregroundStyle(.secondary)
                Text(model.unclassifiedCount > 0 ? L10n.string(.MenuBar.scopeUnclassified(String(model.unclassifiedCount))) : L10n.string(model.issueCount > 0 ? .MenuBar.shelfPartial : .MenuBar.shelfHint))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
        .onExitCommand(perform: close)
    }

    private func tile(_ item: MenuBarObservedItem) -> some View {
        let selected = model.selectedID == item.id
        return Button { model.activate(item.id) } label: {
            HStack(spacing: 9) {
                ArcIcon(.appWindow, size: 20).foregroundStyle(selected ? ArcPalette.orange : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.label.flatMap { $0 == item.displayTitle ? nil : $0 } ?? item.bundleIdentifier ?? "")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? ArcPalette.orange.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? ArcPalette.orange.opacity(0.55) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!item.supportsActivation)
            .help(item.supportsActivation ? item.displayTitle : L10n.string(.MenuBar.accessUnsupported))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onHover { if $0 && item.supportsActivation { model.select(item.id) } }
    }
}

/// 仅在用户显式打开时创建；局部键盘监听不截获其他窗口的输入。
@MainActor
final class MenuBarShelfPanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private let model: MenuBarShelfModel
    private let refresh: () -> Void
    private let openPermission: () -> Void
    private let showAll: () -> Void
    var onDismiss: (() -> Void)?
    private var panel: Panel?
    private var presentationID = UUID()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var sizeObservation: AnyCancellable?
    private var anchorTop: CGFloat?
    var isVisible: Bool { panel?.isVisible == true }

    init(model: MenuBarShelfModel, refresh: @escaping () -> Void, openPermission: @escaping () -> Void, showAll: @escaping () -> Void) {
        self.model = model; self.refresh = refresh; self.openPermission = openPermission; self.showAll = showAll
    }

    func show() throws -> UInt32 {
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens.filter { $0.frame.contains(point) }
        guard screens.count == 1, let screen = screens.first,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            throw MenuBarItemAccessError.displayChanged
        }
        let size = CGSize(width: 540, height: model.preferredHeight)
        guard screen.visibleFrame.width >= size.width + 16, screen.visibleFrame.height >= 400 + max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) + 16 else { throw MenuBarItemAccessError.displayChanged }
        close()
        let presentation = UUID()
        presentationID = presentation
        let window = Panel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MenuBarShelfView(model: model, refresh: refresh, close: { [weak self] in self?.dismiss() }, openPermission: openPermission, showAll: showAll).clipShape(RoundedRectangle(cornerRadius: 14)))
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        let x = max(screen.visibleFrame.minX + 8, min(point.x - size.width / 2, screen.visibleFrame.maxX - size.width - 8))
        window.setFrameOrigin(CGPoint(x: x, y: top - size.height - 8))
        panel = window
        anchorTop = top - 8
        // willChange 的事件在下一轮主循环消费，读取的是完整新状态；上沿固定，搜索框不跳动。
        sizeObservation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.presentationID == presentation else { return }
            self.resizeToContent()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.presentationID == presentation, let panel = self.panel else { return event }
            if event.type != .keyDown {
                if event.window !== panel { self.dismiss() }
                return event
            }
            guard event.window === panel else { return event }
            // 分区选择器和原生按钮保留自己的方向键/回车行为，不被列表导航抢走。
            if let control = panel.firstResponder as? NSControl, !(control is NSTextField) { return event }
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            // 输入法组合中的 Enter / Escape 属于输入法，不触发状态项动作。
            if (panel.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return event }
            switch event.keyCode {
            case 125: model.move(by: 1); return nil
            case 126: model.move(by: -1); return nil
            case 36, 76: model.activate(); return nil
            case 53: self.dismiss(); return nil
            case 123, 124:
                guard !(panel.firstResponder is NSTextView) else { return event }
                model.move(by: event.keyCode == 123 ? -1 : 1); return nil
            default: return event
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.presentationID == presentation else { return }
                self.dismiss()
            }
        }
        window.makeKeyAndOrderFront(nil)
        return id
    }

    private func resizeToContent() {
        guard let panel, panel.isVisible, let anchorTop else { return }
        let height = model.preferredHeight
        guard panel.frame.height != height else { return }
        panel.setFrame(CGRect(x: panel.frame.minX, y: anchorTop - height, width: 540, height: height), display: true)
    }

    func close() {
        sizeObservation = nil; anchorTop = nil
        presentationID = UUID()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        panel?.delegate = nil
        panel?.close(); panel = nil
    }
    private func dismiss() { guard isVisible else { return }; close(); onDismiss?() }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        dismiss()
    }
}
