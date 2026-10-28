import ArcKitPlatform
import AppKit
import SwiftUI

struct AgentSessionSourcesSheet: View {
    @ObservedObject var settings: SettingsEditor<AgentSessionSettings>
    let errors: [UUID: String]
    let isPreview: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.string(.AgentSessions.sourcesManage)).font(.system(size: 22, weight: .semibold)); Spacer(); Button(L10n.string(.Common.close)) { dismiss() }.keyboardShortcut(.defaultAction) }
            Toggle(L10n.string(.AgentSessions.autoEnable), isOn: Binding(get: { settings.settings.isEnabled }, set: { value in settings.update { $0.isEnabled = value } })).toggleStyle(.switch)
            Text(L10n.string(.AgentSessions.autoDetail)).font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(settings.settings.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ArcIcon(.terminal, size: 17).foregroundStyle(ArcPalette.orange)
                                TextField(L10n.string(.AgentSessions.sourceName), text: Binding(get: { settings.settings.sources.first { $0.id == source.id }?.name ?? source.name }, set: { name in edit(source.id) { $0.name = name } })).textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                                Spacer()
                                Button { settings.update { $0.sources.removeAll { $0.id == source.id } } } label: { ArcIcon(.trash2, size: 14) }.buttonStyle(.plain).help(L10n.string(.AgentSessions.removeSource))
                            }
                            Text(source.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            if let message = errors[source.id] { Text(message).font(.system(size: 12)).foregroundStyle(.orange) }
                            ForEach(source.attachmentRoots, id: \.self) { path in
                                HStack { ArcIcon(.image, size: 12); Text(path).lineLimit(1).truncationMode(.middle); Spacer(); Button { edit(source.id) { $0.attachmentRoots.removeAll { $0 == path } } } label: { ArcIcon(.circleX, size: 12) }.buttonStyle(.plain) }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Button(L10n.string(.AgentSessions.allowAttachments)) { chooseDirectory { url in edit(source.id) { if !$0.attachmentRoots.contains(url.path) { $0.attachmentRoots.append(url.path) } } } }.controlSize(.small)
                        }
                        Divider()
                    }
                }
            }.frame(minHeight: 100, maxHeight: 260)
            HStack {
                Button(L10n.string(.AgentSessions.addSource)) { chooseDirectory { add($0) } }
                if !isPreview { Button(L10n.string(.AgentSessions.addDefault)) { add(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) } }
            }
            HStack {
                Picker(L10n.string(.AgentSessions.retention), selection: Binding(get: { settings.settings.retentionDays }, set: { value in settings.update { $0.retentionDays = value } })) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text(L10n.string(.AgentSessions.days(String($0)))).tag($0) }
                }
                Picker(L10n.string(.AgentSessions.capacity), selection: Binding(get: { settings.settings.capacityGB }, set: { value in settings.update { $0.capacityGB = value } })) {
                    ForEach([1, 5, 10, 25, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }
            }.controlSize(.small)
            Text(L10n.string(.AgentSessions.retentionDetail)).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
        }.padding(26).frame(width: 540)
    }
    private func edit(_ id: UUID, _ change: (inout AgentSessionSource) -> Void) { settings.update { if let index = $0.sources.firstIndex(where: { $0.id == id }) { change(&$0.sources[index]) } } }
    private func chooseDirectory(_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { action(url.standardizedFileURL) }
    }
    private func add(_ url: URL) {
        guard url.resolvingSymlinksInPath().path == url.path, FileManager.default.fileExists(atPath: url.path) else { error = L10n.string(.AgentSessions.errorSource); return }
        guard !settings.settings.sources.contains(where: { $0.path == url.path }) else { return }
        settings.update { $0.sources.append(.init(name: "Codex · " + url.lastPathComponent, path: url.path)) }
        error = nil
    }
}
