import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import SwiftUI

/// 侧栏底部的紧凑回执；原因与操作名称通过悬停和辅助功能读取。
struct SettingsPersistenceIndicator: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 2) {
            persistenceContent
            if model.canUndo {
                historyButton(
                    title: model.undoMenuTitle,
                    icon: .undo2,
                    action: model.undo
                )
            }
            if model.canRedo {
                historyButton(
                    title: model.redoMenuTitle,
                    icon: .redo2,
                    action: model.redo
                )
            }
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var persistenceContent: some View {
        switch model.persistenceState {
        case .pending:
            ProgressView().controlSize(.mini)
                .frame(width: 18, height: 22)
                .help(L10n.string(.App.saveSaving))
                .accessibilityLabel(L10n.string(.App.saveSaving))
        case let .saved(date):
            ArcIcon(.checkCircle, size: 12)
                .frame(width: 18, height: 22)
                .foregroundStyle(ArcPalette.sidebarMutedText)
                .help(savedHelp(date))
                .accessibilityHidden(false)
                .accessibilityLabel(L10n.string(.Common.saved))
        case let .failed(message):
            Button {
                model.flush()
            } label: {
                ArcIcon(.triangleAlert, size: 12)
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
                    .foregroundStyle(ArcPalette.red)
            }
            .buttonStyle(.plain)
            .help(L10n.string(.Settings.saveClickRetry(String(describing: message))))
            .accessibilityLabel(L10n.string(.App.menuBarSaveClickRetryFailed(String(describing: message))))
        }
    }

    private func historyButton(
        title: String,
        icon: ArcIconName,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ArcIcon(icon, size: 12)
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func savedHelp(_ date: Date?) -> String {
        guard let date else { return L10n.string(.Settings.saveCurrentSettingsLoadedDisk) }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return L10n.string(.Settings.saveSettingsWrittenVerified(String(describing: formatter.string(from: date))))
    }
}
