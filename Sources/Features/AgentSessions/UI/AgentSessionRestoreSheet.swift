import ArcKitPlatform
import AppKit
import SwiftUI

struct AgentSessionRestoreRequest: Identifiable { let id = UUID(); let payloads: [AgentSessionPayload] }

struct AgentSessionRestoreSheet: View {
    let request: AgentSessionRestoreRequest
    @ObservedObject var model: AgentSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var executable = CodexRecoveryClient.executable()
    @State private var plan: AgentRestorePlan?
    @State private var mappings: [String: String] = [:]
    @State private var replace = false
    @State private var allowPartial = false
    @State private var closed = false
    @State private var planning = false
    @State private var error: String?
    @State private var recovery: URL?
    private var service: CodexSessionRestore { .init(temporaryRoot: model.store.database.paths.temporary) }
    private var hasPartial: Bool { request.payloads.contains { !$0.isComplete } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { ArcIcon(.rotateCcw, size: 22).foregroundStyle(ArcPalette.orange); Text(L10n.string(.AgentSessions.restoreNative)).font(.system(size: 22, weight: .semibold)); Spacer() }
            Text(L10n.string(.AgentSessions.restoreDetail)).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(.AgentSessions.destination)).font(.system(size: 12, weight: .medium))
                    Text(destination?.path ?? L10n.string(.AgentSessions.chooseDestination)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer(); Button(L10n.string(.AgentSessions.chooseDirectory)) { chooseDirectory { destination = $0; closed = false; updatePlan() } }
            }
            HStack {
                Text(executable?.path ?? L10n.string(.AgentSessions.chooseCodex)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(); Button(L10n.string(.AgentSessions.chooseCodex)) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
                    if panel.runModal() == .OK { executable = panel.url }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(Set(request.payloads.map { $0.metadata.project })).sorted(), id: \.self) { project in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: project).lastPathComponent).font(.system(size: 12, weight: .medium))
                                Text(mappings[project] ?? project).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button(L10n.string(.AgentSessions.mapProject)) { chooseDirectory { mappings[project] = $0.path; updatePlan() } }.controlSize(.small)
                        }
                    }
                    Divider()
                    if let plan {
                        ForEach(plan.items) { item in
                            HStack {
                                Text(item.payload.metadata.title).lineLimit(1)
                                Spacer()
                                Text(disposition(item.disposition)).foregroundStyle(item.disposition == .conflict ? Color.orange : Color.secondary)
                            }.font(.system(size: 12))
                        }
                    }
                }
            }.frame(maxHeight: 220)
            if (plan?.conflictCount ?? 0) > 0 {
                Toggle(L10n.string(.AgentSessions.replaceConflicts), isOn: $replace)
                Text(L10n.string(.AgentSessions.replaceDetail)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if hasPartial { Toggle(L10n.string(.AgentSessions.allowPartial), isOn: $allowPartial).font(.system(size: 12)) }
            Toggle(L10n.string(.AgentSessions.confirmClosed), isOn: $closed).font(.system(size: 12))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let recovery, let destination {
                Button(L10n.string(.AgentSessions.rollbackInterrupted)) {
                    model.perform(L10n.string(.AgentSessions.progressRestore)) {
                        try CodexSessionRestore.rollback(recovery, destination: destination)
                        return L10n.string(.AgentSessions.resultRollback)
                    }; dismiss()
                }.disabled(!closed)
            }
            HStack {
                Button(L10n.string(.Common.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if planning { ProgressView().controlSize(.small) }
                Button(L10n.string(.AgentSessions.restoreConfirm), action: execute)
                    .buttonStyle(.borderedProminent).tint(ArcPalette.orange)
                    .disabled(plan == nil || !closed || executable == nil || planning || recovery != nil || (hasPartial && !allowPartial) || model.isWorking || !(plan?.items.contains { $0.disposition == .new || (replace && $0.disposition == .conflict) } ?? false))
            }
        }.padding(26).frame(width: 580)
    }
    private func disposition(_ value: AgentRestorePlan.Item.Disposition) -> String {
        switch value {
        case .new: L10n.string(.AgentSessions.restoreNew)
        case .identical: L10n.string(.AgentSessions.restoreIdentical)
        case .conflict: L10n.string(.AgentSessions.restoreConflict)
        }
    }
    private func chooseDirectory(_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { action(url.standardizedFileURL) }
    }
    private func updatePlan() {
        guard let destination else { return }
        plan = nil; error = nil; recovery = nil; planning = true
        let service = service; let mappings = mappings; let payloads = request.payloads
        Task {
            do {
                let result = try await Task.detached { (try service.plan(payloads, destination: destination, projectMappings: mappings), try CodexSessionRestore.pendingRecovery(at: destination)) }.value
                guard self.destination == destination, self.mappings == mappings else { return }
                plan = result.0; recovery = result.1; planning = false
            } catch { self.error = error.localizedDescription; planning = false }
        }
    }
    private func execute() {
        guard let plan, let executable else { return }
        let service = service; let replace = replace; let allowPartial = allowPartial
        model.perform(L10n.string(.AgentSessions.progressRestore)) {
            let recovery = try service.execute(plan, replaceConflicts: replace, allowPartial: allowPartial, executable: executable)
            return L10n.string(.AgentSessions.resultRestore(recovery.path))
        }
        dismiss()
    }
}
