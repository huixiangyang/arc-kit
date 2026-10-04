import ArcKitPlatform
import ArcKitWindow
import SwiftUI

struct WindowSceneEditorSheet: View {
    @ObservedObject var model: SettingsEditor<WindowManagementSettings>
    @ObservedObject var windowService: WindowManagementService
    let context: WindowSceneEditorContext
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WindowScene
    @State private var inventory: WindowSceneInventory?
    @State private var inventoryAgentLaunchID: UUID?
    @State private var isLoading = false
    @State private var hasLoadedInventory = false
    @State private var notice: String?
    @State private var selectedCandidateIDs: Set<UUID> = []
    @State private var selectsCurrentWindows: Bool

    init(model: SettingsEditor<WindowManagementSettings>, windowService: WindowManagementService, context: WindowSceneEditorContext) {
        self.model = model
        self.windowService = windowService
        self.context = context
        _draft = State(initialValue: context.scene ?? WindowScene(name: "", displays: [], entries: []))
        _selectsCurrentWindows = State(initialValue: context.selectsCurrentWindows)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(context.scene == nil ? L10n.string(.WindowSettings.scenesCapture) : L10n.string(.WindowSettings.scenesEdit))
                    .font(.title3.weight(.semibold))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }.padding(20)
            Divider()
            Form {
                Section {
                    TextField(L10n.string(.WindowSettings.scenesName), text: $draft.name)
                    HStack {
                        Text(L10n.string(.WindowSettings.scenesShortcut))
                        Spacer()
                        WindowHotKeyRecorder(binding: shortcutBinding, duplicateShortcuts: occupiedShortcuts)
                            .frame(width: 190, height: 28)
                        if draft.shortcut != nil {
                            Button(L10n.string(.Common.remove)) { draft.shortcut = nil }.buttonStyle(.borderless)
                        }
                    }
                    if shortcutConflicts {
                        Text(L10n.string(.WindowSettings.scenesShortcutConflict)).font(.caption).foregroundStyle(ArcPalette.orange)
                    }
                    if !model.settings.hotKeysEnabled {
                        Text(L10n.string(.WindowSettings.scenesShortcutsOff)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
                    }
                }
                if selectsCurrentWindows {
                    captureSection
                } else {
                    layoutSection
                    ForEach(draft.entries) { entry in
                        entrySection(entry)
                    }
                    displaySection
                }
                if let notice {
                    Section {
                        Text(notice).font(.caption).foregroundStyle(ArcPalette.orange)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(L10n.string(.WindowSettings.scenesCommitHint))
                    .font(.caption).foregroundStyle(ArcPalette.secondaryText)
                Spacer()
                Button(L10n.string(.Common.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string(.WindowSettings.scenesSave)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shortcutConflicts || selectsCurrentWindows || draft.entries.isEmpty)
            }.padding(16)
        }
        .frame(width: 700, height: 680)
        .task { refreshInventory() }
        .onChange(of: windowService.agentLaunchID) { launchID in
            guard let inventoryAgentLaunchID, inventoryAgentLaunchID != launchID else { return }
            inventory = nil
            selectedCandidateIDs = []
            hasLoadedInventory = false
            notice = L10n.string(.WindowSettings.scenesInventoryExpired)
        }
    }

    private var captureSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(.WindowSettings.scenesChooseWindows)).font(.headline)
                    Text(L10n.string(.WindowSettings.scenesChooseHint)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
                }
                Spacer()
                ArcToolbarButton(title: L10n.string(.WindowSettings.scenesRefresh), symbol: .refreshCw, action: refreshInventory)
                    .disabled(isLoading)
            }
            if let inventory {
                if inventory.candidates.isEmpty {
                    Text(L10n.string(.WindowSettings.scenesNoWindows)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
                }
                ForEach(inventory.candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { selectedCandidateIDs.contains(candidate.id) },
                        set: { selected in
                            if selected { selectedCandidateIDs.insert(candidate.id) }
                            else { selectedCandidateIDs.remove(candidate.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.applicationName).font(.subheadline.weight(.medium))
                            Text(candidate.title.isEmpty ? L10n.string(.WindowSettings.scenesUntitledWindow) : candidate.title)
                                .font(.caption).lineLimit(2)
                            Text(inventory.displays.first(where: { $0.id == candidate.displayID })?.name ?? candidate.displayID)
                                .font(.caption2).foregroundStyle(ArcPalette.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!selectedCandidateIDs.contains(candidate.id) && selectedCandidateIDs.count + preservedEntries.count >= WindowScene.maximumEntryCount)
                }
            }
            if !preservedEntries.isEmpty {
                Text(L10n.string(.WindowSettings.scenesPreservedWindows(preservedEntries.count)))
                    .font(.caption).foregroundStyle(ArcPalette.orange)
            }
            HStack {
                if !draft.entries.isEmpty {
                    Button(L10n.string(.Common.cancel)) { selectsCurrentWindows = false }
                }
                Spacer()
                Button(L10n.string(.WindowSettings.scenesUseSelected)) { captureSelection() }
                    .disabled((selectedCandidateIDs.isEmpty && preservedEntries.isEmpty) || isLoading || inventory == nil)
            }
            Text(L10n.string(.WindowSettings.scenesSelectionCount(selectedCandidateIDs.count, WindowScene.maximumEntryCount)))
                .font(.caption).foregroundStyle(ArcPalette.secondaryText)
        }
    }

    private var layoutSection: some View {
        Section {
            WindowSceneLayoutPreview(displays: draft.displays, entries: draft.entries)
                .frame(height: 100)
                .accessibilityLabel(L10n.string(.WindowSettings.scenesLayoutPreview))
            Picker(L10n.string(.WindowSettings.scenesFocus), selection: $draft.focusEntryID) {
                Text(L10n.string(.WindowSettings.scenesKeepFocus)).tag(Optional<UUID>.none)
                ForEach(draft.entries) { entry in
                    Text(entryLabel(entry)).tag(Optional(entry.id))
                }
            }
            HStack {
                Text(L10n.string(.WindowSettings.scenesCounts(draft.entries.count, draft.displays.count)))
                    .font(.caption).foregroundStyle(ArcPalette.secondaryText)
                Spacer()
                Button(L10n.string(.WindowSettings.scenesReselect)) {
                    selectedCandidateIDs = []
                    hasLoadedInventory = false
                    selectsCurrentWindows = true
                    refreshInventory()
                }
            }
        }
    }

    private func entrySection(_ entry: WindowSceneEntry) -> some View {
        Section {
            HStack(alignment: .top) {
                ArcIcon(.appWindow, size: 18).foregroundStyle(ArcPalette.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.applicationName).font(.subheadline.weight(.semibold))
                    Text(entry.savedTitle.isEmpty ? L10n.string(.WindowSettings.scenesUntitledWindow) : entry.savedTitle)
                        .font(.caption).foregroundStyle(ArcPalette.secondaryText).lineLimit(2)
                }
                Spacer()
                Button(L10n.string(.Common.remove)) { removeEntry(entry.id) }
                    .buttonStyle(.borderless).foregroundStyle(ArcPalette.red)
            }
            Picker(L10n.string(.WindowSettings.scenesMatchRule), selection: Binding(
                get: { draft.entries.first(where: { $0.id == entry.id })?.titleMatchMode ?? .exact },
                set: { mode in updateEntry(entry.id) {
                    $0.titleMatchMode = mode
                    $0.titleMatchValue = mode == .application ? "" : ($0.titleMatchValue.isEmpty ? $0.savedTitle : $0.titleMatchValue)
                    $0.sessionHint = nil
                } }
            )) {
                ForEach(WindowSceneTitleMatchMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            if entry.titleMatchMode != .application {
                TextField(L10n.string(.WindowSettings.scenesMatchValue), text: Binding(
                    get: { draft.entries.first(where: { $0.id == entry.id })?.titleMatchValue ?? "" },
                    set: { value in updateEntry(entry.id) { $0.titleMatchValue = value; $0.sessionHint = nil } }
                ))
            }
            Text(L10n.string(.WindowSettings.scenesMatchHint)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
            if let inventory {
                let candidates = inventory.candidates.filter { $0.bundleIdentifier == entry.bundleIdentifier }
                HStack {
                    Text(L10n.string(.WindowSettings.scenesRebind))
                    Spacer()
                    Menu {
                        ForEach(candidates) { candidate in
                            Button(candidateLabel(candidate, inventory: inventory)) { rebind(entryID: entry.id, candidate: candidate) }
                                .disabled(draft.entries.contains { other in
                                    other.id != entry.id && other.sessionHint != nil && other.sessionHint == candidate.sessionHint
                                })
                        }
                    } label: {
                        Text(candidates.isEmpty ? L10n.string(.WindowSettings.scenesNoMatchingWindows) : L10n.string(.WindowSettings.scenesChooseReplacement))
                    }
                    .disabled(candidates.isEmpty)
                }
            }
        }
    }

    private var displaySection: some View {
        Section(L10n.string(.WindowSettings.scenesDisplays)) {
            Text(L10n.string(.WindowSettings.scenesDisplayHint)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
            ForEach(draft.displays) { display in
                HStack {
                    ArcIcon(.monitor, size: 16)
                    Text(display.name)
                    Spacer()
                    if let inventory, !inventory.displays.contains(where: { $0.id == display.id }) {
                        Text(L10n.string(.WindowSettings.scenesDisplayMissing)).font(.caption).foregroundStyle(ArcPalette.orange)
                    }
                    if let inventory {
                        Menu(L10n.string(.WindowSettings.scenesRemapDisplay)) {
                            ForEach(inventory.displays) { replacement in
                                Button(replacement.name) { remapDisplay(display.id, to: replacement) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Button(L10n.string(.WindowSettings.scenesRefresh), action: refreshInventory).disabled(isLoading)
        }
    }

    private var occupiedShortcuts: Set<String> {
        let layouts = model.settings.bindings.filter(\.isEnabled).map(\.shortcutIdentifier)
        let scenes = model.settings.scenes.filter { $0.id != draft.id }.compactMap { scene in
            scene.shortcut.flatMap { $0.isEnabled ? $0.shortcutIdentifier : nil }
        }
        return Set(layouts + scenes)
    }

    private var shortcutConflicts: Bool {
        guard let shortcut = draft.shortcut, shortcut.isEnabled else { return false }
        return occupiedShortcuts.contains(shortcut.shortcutIdentifier)
    }

    private var shortcutBinding: Binding<WindowHotKeyBinding> {
        Binding(get: {
            // 录制器只借用现有按键校验；占位 action 不会写入场景模型。
            WindowHotKeyBinding(action: .leftHalf, keyCode: draft.shortcut?.keyCode ?? 0,
                keyEquivalent: draft.shortcut?.keyEquivalent ?? "A", modifiers: draft.shortcut?.modifiers ?? [],
                isEnabled: draft.shortcut?.isEnabled ?? false)
        }, set: { binding in
            draft.shortcut = binding.isEnabled ? WindowSceneShortcut(keyCode: binding.keyCode,
                keyEquivalent: binding.keyEquivalent, modifiers: binding.modifiers) : nil
        })
    }

    private func refreshInventory() {
        guard !isLoading else { return }
        isLoading = true
        windowService.fetchSceneInventory { result in
            isLoading = false
            switch result {
            case .success(let value):
                inventory = value
                inventoryAgentLaunchID = windowService.agentLaunchID
                if selectsCurrentWindows, !hasLoadedInventory {
                    selectedCandidateIDs = Set(value.candidates.filter { matchingSavedEntry(for: $0, inventory: value) != nil }.map(\.id))
                } else {
                    selectedCandidateIDs.formIntersection(Set(value.candidates.map(\.id)))
                }
                hasLoadedInventory = true
                notice = nil
            case .failure(let error):
                inventory = nil
                notice = error.localizedDescription
            }
        }
    }

    private func captureSelection() {
        guard inventory != nil, !isLoading else { return }
        isLoading = true
        // 勾选后再读取一次当前几何，避免用户在编辑期间重新摆放窗口却保存旧坐标。
        windowService.fetchSceneInventory { result in
            isLoading = false
            switch result {
            case .success(let current):
                inventory = current
                inventoryAgentLaunchID = windowService.agentLaunchID
                let currentIDs = Set(current.candidates.map(\.id))
                guard selectedCandidateIDs.isSubset(of: currentIDs) else {
                    selectedCandidateIDs.formIntersection(currentIDs)
                    notice = L10n.string(.WindowSettings.scenesSelectionExpired)
                    return
                }
                captureSelection(using: current)
            case .failure(let error):
                notice = error.localizedDescription
            }
        }
    }

    private var preservedEntries: [WindowSceneEntry] {
        guard let inventory else { return [] }
        return WindowSceneCapture.preservedEntries(scene: draft, inventory: inventory)
    }

    private func captureSelection(using inventory: WindowSceneInventory) {
        do {
            let preservedCount = WindowSceneCapture.preservedEntries(scene: draft, inventory: inventory).count
            draft = try WindowSceneCapture.update(scene: draft, inventory: inventory, selectedIDs: selectedCandidateIDs)
            notice = preservedCount == 0 ? nil : L10n.string(.WindowSettings.scenesPreservedWindows(preservedCount))
            selectsCurrentWindows = false
        } catch {
            notice = error.localizedDescription
        }
    }

    private func rebind(entryID: UUID, candidate: WindowSceneCandidate) {
        // 重新绑定仅更新窗口身份，保留用户保存的目标位置和显示器。
        updateEntry(entryID) {
            $0.savedTitle = candidate.title
            $0.titleMatchMode = candidate.title.isEmpty ? .application : .exact
            $0.titleMatchValue = candidate.title
            $0.sessionHint = candidate.sessionHint
        }
        notice = L10n.string(.WindowSettings.scenesRebound)
    }

    private func matchingSavedEntry(for candidate: WindowSceneCandidate, inventory: WindowSceneInventory) -> WindowSceneEntry? {
        WindowSceneCapture.matchingEntry(for: candidate, scene: draft, inventory: inventory)
    }

    private func remapDisplay(_ id: String, to replacement: WindowSceneDisplay) {
        for index in draft.entries.indices where draft.entries[index].displayID == id {
            draft.entries[index].displayID = replacement.id
        }
        draft.displays.removeAll { $0.id == id || $0.id == replacement.id }
        draft.displays.append(replacement)
    }

    private func updateEntry(_ id: UUID, _ update: (inout WindowSceneEntry) -> Void) {
        guard let index = draft.entries.firstIndex(where: { $0.id == id }) else { return }
        update(&draft.entries[index])
    }

    private func removeEntry(_ id: UUID) {
        draft.entries.removeAll { $0.id == id }
        if draft.focusEntryID == id { draft.focusEntryID = nil }
        draft.displays.removeAll { display in !draft.entries.contains(where: { $0.displayID == display.id }) }
    }

    private func save() {
        do {
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try draft.validate()
            if !model.settings.scenes.contains(where: { $0.id == draft.id }), model.settings.scenes.count >= WindowScene.maximumSceneCount {
                throw WindowSceneClientError(message: L10n.string(.WindowSettings.scenesLimit(WindowScene.maximumSceneCount)))
            }
            guard !shortcutConflicts else { throw WindowSceneClientError(message: L10n.string(.WindowSettings.scenesShortcutConflict)) }
            model.update(actionName: L10n.string(.WindowSettings.scenesSave)) { settings in
                if let index = settings.scenes.firstIndex(where: { $0.id == draft.id }) { settings.scenes[index] = draft }
                else { settings.scenes.append(draft) }
            }
            guard model.settings.scenes.contains(draft) else {
                throw WindowSceneClientError(message: L10n.string(.WindowSettings.scenesSaveRejected))
            }
            dismiss()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func entryLabel(_ entry: WindowSceneEntry) -> String {
        entry.savedTitle.isEmpty ? entry.applicationName : "\(entry.applicationName) — \(entry.savedTitle)"
    }

    private func candidateLabel(_ candidate: WindowSceneCandidate, inventory: WindowSceneInventory) -> String {
        let title = candidate.title.isEmpty ? L10n.string(.WindowSettings.scenesUntitledWindow) : candidate.title
        let display = inventory.displays.first(where: { $0.id == candidate.displayID })?.name ?? ""
        return "\(title) · \(display) · \(Int(candidate.frame.minX)), \(Int(candidate.frame.minY))"
    }
}
