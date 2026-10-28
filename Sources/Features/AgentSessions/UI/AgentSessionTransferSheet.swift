import ArcKitPlatform
import AppKit
import SwiftUI

struct AgentSessionTransferRequest: Identifiable {
    enum Mode { case importFile(URL), exportFiles([AgentSessionPayload]) }
    let id = UUID()
    let mode: Mode
    var importing: Bool { if case .importFile = mode { true } else { false } }
}

struct AgentSessionTransferSheet: View {
    let request: AgentSessionTransferRequest
    @ObservedObject var model: AgentSessionModel
    @State private var password = ""
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ArcIcon(.lockKeyhole, size: 23).foregroundStyle(ArcPalette.orange)
                Text(L10n.string(request.importing ? .AgentSessions.importArchive : .AgentSessions.exportArchive)).font(.system(size: 21, weight: .semibold))
            }
            Text(L10n.string(request.importing ? .AgentSessions.importDetail : .AgentSessions.exportDetail)).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            SecureField(L10n.string(.AgentSessions.password), text: $password).textFieldStyle(.roundedBorder)
            if !request.importing { SecureField(L10n.string(.AgentSessions.passwordConfirm), text: $confirmation).textFieldStyle(.roundedBorder) }
            HStack {
                Button(L10n.string(.Common.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string(request.importing ? .AgentSessions.importArchive : .AgentSessions.exportArchive), action: submit)
                    .buttonStyle(.borderedProminent).tint(ArcPalette.orange).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || (!request.importing && (password.count < 12 || password != confirmation)) || model.isWorking)
            }
        }.padding(26).frame(width: 440)
    }
    private func submit() {
        let secret = password
        switch request.mode {
        case let .importFile(url): model.importArchive(url, password: secret)
        case let .exportFiles(payloads):
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Agent-Sessions-" + SettingsBackupPresentation.fileTimestamp() + "-" + String(UUID().uuidString.prefix(6)) + ".arckitsessions"
            panel.title = L10n.string(.AgentSessions.exportArchive)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.perform(L10n.string(.AgentSessions.progressExport)) {
                try AgentSessionArchive.export(payloads, password: secret, to: url)
                return L10n.string(.AgentSessions.resultExport(url.path))
            }
        }
        password = ""; confirmation = ""; dismiss()
    }
}
