import ArcKitPlatform
import AppKit
import SwiftUI

struct AgentSessionsSection: View {
    @ObservedObject var model: AgentSessionModel
    @ObservedObject var settings: SettingsEditor<AgentSessionSettings>
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var searchMessages = false
    @State private var searchOwner = UUID()
    @State private var focusedSearchHit: AgentSessionSearchHit?
    @State private var sourceID: UUID?
    @State private var project = ""
    @State private var showSources = false
    @State private var versionID: UUID?
    @State private var transcript: [AgentTranscriptEntry] = []
    @State private var previewError: String?
    @State private var previewLoading = false
    @State private var transcriptSearch = ""
    @State private var transfer: AgentSessionTransferRequest?
    @State private var restore: AgentSessionRestoreRequest?
    @State private var actionError: String?
    @State private var preparingTransfer = false

    init(model: AgentSessionModel, settings: SettingsEditor<AgentSessionSettings>, initialSelection: Set<String> = [],
         initialSearch: String? = nil, initialHit: AgentSessionSearchHit? = nil) {
        self.model = model; self.settings = settings
        _selection = State(initialValue: initialHit.map { Set([$0.version.key.value]) } ?? initialSelection)
        _search = State(initialValue: initialSearch ?? "")
        _searchMessages = State(initialValue: initialSearch != nil)
        _focusedSearchHit = State(initialValue: initialHit)
        _versionID = State(initialValue: initialHit?.version.id)
    }
    private var searchingMessages: Bool { searchMessages && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searchRequest: AgentSessionSearchRequest {
        .init(text: searchMessages ? search : "", sourceID: sourceID, project: project)
    }
    private var projectOptions: [String] {
        Array(Set(searchMessages ? model.versions.map { $0.metadata.project } : model.rows.map { $0.metadata.project })).sorted()
    }
    private var filteredRows: [AgentSessionRow] {
        if searchingMessages {
            let matching = Set(model.searchResult.hits.map { $0.version.key })
            return model.rows.filter { matching.contains($0.key) }
        }
        return model.rows.filter { row in
            (sourceID == nil || row.key.sourceID == sourceID) && (project.isEmpty || row.metadata.project == project) &&
                (search.isEmpty || [row.metadata.title, row.metadata.project, row.key.sessionID].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    private var hasFilter: Bool { sourceID != nil || !project.isEmpty || !search.isEmpty }
    private var selectedRow: AgentSessionRow? { selection.count == 1 ? model.rows.first { selection.contains($0.id) } : nil }
    private var history: [AgentSessionVersion] { guard let row = selectedRow else { return [] }; return model.versions.filter { $0.key == row.key } }
    private var version: AgentSessionVersion? { history.first { $0.id == versionID } ?? history.first }
    private var selectedVersions: [AgentSessionVersion] {
        if selection.count == 1, let version { return [version] }
        return model.rows.filter { selection.contains($0.id) }.compactMap(\.latest)
    }
    var body: some View {
        GeometryReader { geometry in
        // 主窗口最窄为 720 pt，扣除侧栏后以列表/详情单栏切换，不挤压正文。
        let compact = geometry.size.width < 720
        VStack(spacing: 0) {
            if !compact || selectedRow == nil {
                header(compact: compact)
                filters(compact: compact)
            }
            if !model.sourceErrors.isEmpty {
                HStack(spacing: 8) {
                    ArcIcon(.triangleAlert, size: 14).foregroundStyle(.orange)
                    Text(L10n.string(.AgentSessions.sourceErrors(String(model.sourceErrors.count)))).font(.system(size: 12))
                    Spacer()
                    Button(L10n.string(.AgentSessions.sourcesManage)) { showSources = true }.buttonStyle(.plain)
                }.padding(.horizontal, 22).padding(.vertical, 9).background(Color.orange.opacity(0.08))
            }
            if model.rows.isEmpty {
                emptyState
            } else if compact {
                if selectedRow != nil {
                    VStack(spacing: 0) {
                        HStack {
                            Button { selection.removeAll() } label: {
                                HStack(spacing: 5) { ArcIcon(.chevronRight, size: 12).rotationEffect(.degrees(180)); Text(L10n.string(.AgentSessions.backToList)) }
                            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                        Divider()
                        detail
                    }
                } else { sessionList }
            } else {
                HSplitView {
                    sessionList.frame(minWidth: 300, idealWidth: 430)
                    detail.frame(minWidth: 290, idealWidth: 360)
                }
            }
            footer
        }
        }
        .appBackgroundSurface()
        .environment(\.locale, L10n.locale)
        .sheet(isPresented: $showSources) { AgentSessionSourcesSheet(settings: settings, errors: model.sourceErrors, isPreview: model.isPreview) }
        .sheet(item: $transfer) { AgentSessionTransferSheet(request: $0, model: model) }
        .sheet(item: $restore) { AgentSessionRestoreSheet(request: $0, model: model) }
        .alert(L10n.string(.AgentSessions.actionFailed), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) { Button(L10n.string(.Common.close)) { actionError = nil } } message: { Text(actionError ?? "") }
        .onChange(of: selection) { value in
            if let hit = focusedSearchHit, value == [hit.version.key.value] { versionID = hit.version.id }
            else { focusedSearchHit = nil; versionID = nil }
            transcriptSearch = ""
        }
        .onChange(of: search) { _ in retainVisibleSelection() }
        .onChange(of: searchMessages) { _ in
            selection.removeAll(); focusedSearchHit = nil
            if !project.isEmpty && !projectOptions.contains(project) { project = "" }
        }
        .task(id: searchRequest) { model.searchBackups(searchRequest, owner: searchOwner) }
        .onDisappear { model.endSearch(owner: searchOwner) }
        .onChange(of: sourceID) { _ in retainVisibleSelection() }
        .onChange(of: project) { _ in retainVisibleSelection() }
        .task(id: version?.id) { await loadPreview() }
        .onReceive(model.$rows) { rows in selection.formIntersection(Set(rows.map(\.id))) }
    }
    @ViewBuilder private func header(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 13) { heading; HStack { Spacer(); headerActions } }
            } else { HStack(spacing: 14) { heading; Spacer(); headerActions } }
        }.padding(.horizontal, 22).padding(.top, compact ? 16 : 22).padding(.bottom, compact ? 14 : 20)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(.AgentSessions.pageTitle)).font(.system(size: 26, weight: .semibold, design: .rounded))
            HStack(spacing: 5) {
                ArcIcon(settings.settings.isEnabled ? .shieldCheck : .archive, size: 12)
                Text(L10n.string(settings.settings.isEnabled ? .AgentSessions.autoOn : .AgentSessions.autoOff))
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var headerActions: some View {
        HStack(spacing: 12) {
            Button { showSources = true } label: { Label { Text(L10n.string(.AgentSessions.sourcesManage)) } icon: { ArcIcon(.folderCog, size: 15) } }
            Menu {
                Button(L10n.string(.AgentSessions.importArchive), action: selectImport)
                Button(L10n.string(.AgentSessions.exportArchive)) { exportSelection() }.disabled(selectedVersions.isEmpty)
            } label: { ArcIcon(.arrowLeftRight, size: 16) }.menuStyle(.borderlessButton).fixedSize().help(L10n.string(.AgentSessions.transferTitle))
            Button {
                let keys = Set(model.rows.filter { selection.contains($0.id) }.map(\.key))
                model.refresh(backup: true, keys: keys.isEmpty ? (hasFilter ? Set(filteredRows.map(\.key)) : nil) : keys)
            } label: {
                Label { Text(L10n.string(selection.isEmpty ? (hasFilter ? .AgentSessions.backupFiltered : .AgentSessions.backupAll) : .AgentSessions.backupSelected)) } icon: { ArcIcon(.hardDriveUpload, size: 15) }
            }.buttonStyle(.borderedProminent).tint(ArcPalette.orange).disabled(model.isWorking || settings.hasUncommittedChanges || settings.settings.sources.isEmpty || (hasFilter && filteredRows.isEmpty))
        }
    }
    @ViewBuilder private func filters(compact: Bool) -> some View {
        Group {
            if compact { VStack(spacing: 8) { searchField; HStack { filterPickers; Spacer() } } }
            else { HStack(spacing: 10) { searchField; filterPickers } }
        }.controlSize(.small).padding(.horizontal, 22).padding(.bottom, compact ? 8 : 14)
    }
    private var searchField: some View {
        HStack(spacing: 7) {
            ArcIcon(.search, size: 14).foregroundStyle(.secondary)
            TextField(L10n.string(searchMessages ? .AgentSessions.searchMessages : .AgentSessions.search), text: $search).textFieldStyle(.plain)
            Picker(L10n.string(.AgentSessions.searchScope), selection: $searchMessages) {
                Text(L10n.string(.AgentSessions.searchMetadata)).tag(false)
                Text(L10n.string(.AgentSessions.searchBody)).tag(true)
            }.labelsHidden().fixedSize().help(L10n.string(.AgentSessions.searchBodyHint))
        }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
    private var filterPickers: some View {
        HStack(spacing: 10) {
            Picker(L10n.string(.AgentSessions.source), selection: $sourceID) {
                Text(L10n.string(.AgentSessions.allSources)).tag(nil as UUID?)
                ForEach(settings.settings.sources) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(maxWidth: 140)
            Picker(L10n.string(.AgentSessions.project), selection: $project) {
                Text(L10n.string(.AgentSessions.allProjects)).tag("")
                ForEach(projectOptions, id: \.self) { path in Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) }
            }.labelsHidden().frame(maxWidth: 140)
            Button { model.refresh() } label: { ArcIcon(.refreshCw, size: 15) }.buttonStyle(.plain).help(L10n.string(.AgentSessions.refresh)).disabled(model.isWorking)
        }
    }
    @ViewBuilder private var sessionList: some View {
        if searchingMessages { messageSearchResults }
        else { metadataList }
    }
    private var metadataList: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.string(.AgentSessions.columnSession)); Spacer(); Text(L10n.string(.AgentSessions.columnProtection)) }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            List(selection: $selection) {
                ForEach(filteredRows) { row in
                    HStack(alignment: .top, spacing: 11) {
                        ArcIcon(row.metadata.parentID == nil ? .terminal : .cornerDownLeft, size: 16).foregroundStyle(.secondary).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.metadata.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack(spacing: 5) {
                                Text(URL(fileURLWithPath: row.metadata.project).lastPathComponent)
                                Text("·")
                                Text(row.metadata.modifiedAt, style: .date)
                            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 5) {
                            ArcIcon(statusIcon(row), size: 14).foregroundStyle(statusColor(row))
                            Text(status(row)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 7).tag(row.id)
                }
            }.listStyle(.inset(alternatesRowBackgrounds: false))
            if filteredRows.isEmpty { Text(L10n.string(.AgentSessions.noMatches)).font(.system(size: 13)).foregroundStyle(.secondary).padding(20) }
        }
    }
    private var messageSearchResults: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string(.AgentSessions.searchProtectedMessages))
                Spacer()
                if model.isSearching { ProgressView().controlSize(.mini) }
                else { Text(L10n.string(.AgentSessions.searchSessionCount(String(model.searchResult.hits.count)))) }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if let failure = model.searchFailure {
                VStack(alignment: .leading, spacing: 12) {
                    Text(failure).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L10n.string(.AgentSessions.searchRetry)) { model.searchBackups(searchRequest, owner: searchOwner) }
                }.padding(18)
                Spacer()
            } else if model.searchResult.hits.isEmpty {
                VStack(spacing: 10) {
                    Text(L10n.string(model.isSearching ? .AgentSessions.searchPreparing : .AgentSessions.noMatches)).font(.system(size: 13))
                    Text(L10n.string(.AgentSessions.searchBodyHint)).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.searchResult.hits) { hit in
                        Button { selectSearchHit(hit) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(hit.version.metadata.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Text(hit.excerpt).font(.system(size: 12)).lineLimit(4).foregroundStyle(.secondary)
                                HStack(spacing: 5) {
                                    Text(URL(fileURLWithPath: hit.version.metadata.project).lastPathComponent)
                                    Text("·")
                                    Text(hit.version.capturedAt, style: .date)
                                    Spacer(minLength: 4)
                                    ArcIcon(.arrowUpRight, size: 12)
                                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                .background(focusedSearchHit?.id == hit.id ? ArcPalette.orange.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L10n.string(.AgentSessions.searchOpenMessage))
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: false))
                if model.searchResult.hasMore {
                    Text(L10n.string(.AgentSessions.searchLimit(String(model.searchResult.hits.count))))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
                }
            }
        }
    }
    private func selectSearchHit(_ hit: AgentSessionSearchHit) {
        focusedSearchHit = hit; selection = [hit.version.key.value]; versionID = hit.version.id; transcriptSearch = ""
    }
    private var focusedEntryID: Int? { focusedSearchHit?.version.id == version?.id ? focusedSearchHit?.entryID : nil }
    @ViewBuilder private var detail: some View {
        if let row = selectedRow {
            let metadata = version?.metadata ?? row.metadata
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(row.sourceName).font(.system(size: 11, weight: .semibold)).foregroundStyle(ArcPalette.orange)
                        Spacer()
                        if metadata.archived { Text(L10n.string(.AgentSessions.archived)).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Text(metadata.title).font(.system(size: 19, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    Text(metadata.project).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    if metadata.parentID != nil || !metadata.childIDs.isEmpty {
                        HStack(spacing: 10) {
                            if let parent = metadata.parentID {
                                Button(L10n.string(.AgentSessions.viewParent)) { selection = [AgentSessionKey(sourceID: row.key.sourceID, sessionID: parent).value] }
                                    .disabled(!model.rows.contains(where: { $0.key.sourceID == row.key.sourceID && $0.key.sessionID == parent }))
                            }
                            if !metadata.childIDs.isEmpty {
                                Menu(L10n.string(.AgentSessions.viewChildren(String(metadata.childIDs.count)))) {
                                    ForEach(metadata.childIDs, id: \.self) { id in
                                        let related = model.rows.first { $0.key.sourceID == row.key.sourceID && $0.key.sessionID == id }
                                        Button(related?.metadata.title ?? id) { selection = [AgentSessionKey(sourceID: row.key.sourceID, sessionID: id).value] }.disabled(related == nil)
                                    }
                                }.fixedSize()
                            }
                        }.controlSize(.small)
                    }
                    if version == nil || row.hasChanges || row.latest?.complete == false {
                        Button(L10n.string(.AgentSessions.backupSelected)) { model.refresh(backup: true, keys: [row.key]) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(model.isWorking || settings.hasUncommittedChanges || row.sourcePath == nil || row.sourceMissing)
                    }
                    if let version {
                        HStack(spacing: 8) {
                            Button(L10n.string(.AgentSessions.restoreNative)) { prepareRestore() }.buttonStyle(.borderedProminent).tint(ArcPalette.orange)
                            Button { exportSelection() } label: { ArcIcon(.hardDriveUpload, size: 14) }.help(L10n.string(.AgentSessions.exportArchive))
                            Button { model.setRetained(version, !version.retained) } label: { ArcIcon(version.retained ? .lockKeyhole : .lockKeyholeOpen, size: 14) }.help(L10n.string(version.retained ? .AgentSessions.unpinVersion : .AgentSessions.pinVersion))
                        }.controlSize(.small).disabled(model.isWorking || preparingTransfer)
                    }
                }.padding(20)
                if !history.isEmpty {
                    HStack(spacing: 8) {
                        ArcIcon(.rows3, size: 13).foregroundStyle(.secondary)
                        Picker(L10n.string(.AgentSessions.version), selection: Binding(get: { version?.id }, set: { versionID = $0 })) {
                            ForEach(history) { v in Text(versionTitle(v)).tag(Optional(v.id)) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }.padding(.horizontal, 18).padding(.bottom, 13)
                }
                Divider()
                if let version, !version.complete {
                    Text(L10n.string(.AgentSessions.partialDetail)).font(.system(size: 12)).foregroundStyle(.orange).padding(16)
                }
                HStack(spacing: 6) {
                    ArcIcon(.search, size: 12).foregroundStyle(.secondary)
                    TextField(L10n.string(.AgentSessions.searchTranscript), text: $transcriptSearch).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(14)
                if previewLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let previewError { Text(previewError).foregroundStyle(.secondary).padding(20); Spacer() }
                else if version == nil { Text(L10n.string(.AgentSessions.backupToPreview)).foregroundStyle(.secondary).padding(20); Spacer() }
                else {
                    ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(transcript.filter { transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch) }) { entry in
                                VStack(alignment: .leading, spacing: 7) {
                                    if ["user", "assistant"].contains(entry.kind) {
                                        Text(L10n.string(entry.kind == "user" ? .AgentSessions.roleUser : .AgentSessions.roleAssistant)).font(.system(size: 10, weight: .bold)).foregroundStyle(entry.kind == "user" ? ArcPalette.orange : Color.secondary)
                                        Text(entry.text).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        DisclosureGroup {
                                            Text(entry.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.top, 7)
                                        } label: { Text(entry.kind).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                                    }
                                }.padding(focusedEntryID == entry.id ? 10 : 0)
                                    .background(focusedEntryID == entry.id ? ArcPalette.orange.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .id(entry.id)
                            }
                        }.padding(18)
                    }.task(id: focusedEntryID) {
                        if let focusedEntryID {
                            await Task.yield()
                            proxy.scrollTo(focusedEntryID, anchor: .top)
                        }
                    }
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 14) {
                ArcIcon(.archive, size: 32).foregroundStyle(.tertiary)
                Text(L10n.string(selection.isEmpty ? .AgentSessions.selectSession : .AgentSessions.multiSelection(String(selection.count)))).font(.system(size: 14)).foregroundStyle(.secondary)
                if !selectedVersions.isEmpty { Button(L10n.string(.AgentSessions.exportArchive)) { exportSelection() }.disabled(model.isWorking) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            ArcIcon(.archive, size: 38).foregroundStyle(ArcPalette.orange)
            Text(L10n.string(.AgentSessions.emptyTitle)).font(.system(size: 27, weight: .semibold))
            Text(L10n.string(.AgentSessions.emptyDetail)).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).frame(maxWidth: 430, alignment: .leading)
            HStack(spacing: 12) {
                Button(L10n.string(.AgentSessions.addSource)) { showSources = true }.buttonStyle(.borderedProminent).tint(ArcPalette.orange)
                Button(L10n.string(.AgentSessions.importArchive), action: selectImport)
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 48)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.isWorking || preparingTransfer { ProgressView().controlSize(.mini); Text(model.progress ?? L10n.string(.AgentSessions.progressRead)) }
                else if let failure = model.failure { ArcIcon(.triangleAlert, size: 13).foregroundStyle(.orange); Text(failure).lineLimit(2) }
                else if let feedback = model.feedback { ArcIcon(.checkCircle, size: 13); Text(feedback).lineLimit(2) }
                else { Text(L10n.string(.AgentSessions.footerCount(String(model.rows.count), L10n.fileSize(model.bytes)))) }
                Spacer(minLength: 8)
                if !model.isWorking, let checked = model.lastChecked { Text(checked, style: .time).monospacedDigit().help(L10n.string(.AgentSessions.lastCheck)) }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 11)
        }
    }
    private func retainVisibleSelection() { selection.formIntersection(Set(filteredRows.map(\.id))) }
    private func status(_ row: AgentSessionRow) -> String {
        if row.sourceMissing { return L10n.string(.AgentSessions.statusDeleted) }
        guard let latest = row.latest else { return L10n.string(.AgentSessions.statusUnprotected) }
        if !latest.complete { return L10n.string(.AgentSessions.statusPartial) }
        return L10n.string(row.hasChanges ? .AgentSessions.statusChanged : .AgentSessions.statusProtected)
    }
    private func statusIcon(_ row: AgentSessionRow) -> ArcIconName { row.sourceMissing ? .archive : (row.latest?.complete == true && !row.hasChanges ? .shieldCheck : .circleHalf) }
    private func statusColor(_ row: AgentSessionRow) -> Color { row.latest?.complete == true && !row.hasChanges ? .secondary : ArcPalette.orange }
    private func versionTitle(_ value: AgentSessionVersion) -> String { SettingsBackupPresentation.localizedDateTime(value.capturedAt) + (value.retained ? " · " + L10n.string(.AgentSessions.retained) : "") }
    private func loadPreview() async {
        transcript = []; previewError = nil
        guard let version else { return }
        let id = version.id; let store = model.store; previewLoading = true
        do {
            let entries = try await Task.detached { try CodexSessionAdapter.transcript(store.payload(version).rollout) }.value
            guard !Task.isCancelled, self.version?.id == id else { return }
            transcript = entries; previewLoading = false
        } catch { guard !Task.isCancelled else { return }; previewError = error.localizedDescription; previewLoading = false }
    }
    private func selectImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false
        panel.title = L10n.string(.AgentSessions.importArchive)
        if panel.runModal() == .OK, let url = panel.url { transfer = .init(mode: .importFile(url)) }
    }
    private func exportSelection() {
        guard !preparingTransfer else { return }; preparingTransfer = true
        let selected = selectedVersions
        Task {
            defer { preparingTransfer = false }
            do { transfer = .init(mode: .exportFiles(try await model.payloads(for: selected))) }
            catch { actionError = error.localizedDescription }
        }
    }
    private func prepareRestore() {
        guard !preparingTransfer else { return }; preparingTransfer = true
        let selected = selectedVersions
        Task {
            defer { preparingTransfer = false }
            do { restore = .init(payloads: try await model.payloads(for: selected)) }
            catch { actionError = error.localizedDescription }
        }
    }
}
