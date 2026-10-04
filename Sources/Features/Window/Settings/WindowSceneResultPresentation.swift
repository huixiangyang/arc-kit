import ArcKitPlatform
import ArcKitWindow
import SwiftUI

public extension WindowSceneExecutionReport {
    var summary: String {
        if operation == .undo {
            return L10n.string(.WindowSettings.scenesUndoSummary(sceneName, successfulCount, items.count))
        }
        return L10n.string(.WindowSettings.scenesApplySummary(sceneName, successfulCount, items.count))
    }
}

struct WindowSceneResultSection: View {
    let report: WindowSceneExecutionReport
    let scene: WindowScene?
    @ObservedObject var windowService: WindowManagementService
    let editScene: (UUID) -> Void

    var body: some View {
        Section(L10n.string(.WindowSettings.scenesLastResult)) {
            HStack(spacing: 10) {
                ArcIcon(report.needsAttention ? .triangleAlert : .checkCircle, size: 18)
                    .foregroundStyle(report.needsAttention ? ArcPalette.orange : Color.accentColor)
                Text(report.summary).font(.subheadline.weight(.medium))
                Spacer()
                if let token = report.undoToken {
                    Button(L10n.string(.WindowSettings.scenesUndo)) { windowService.undoScene(token: token) }
                        .disabled(windowService.isApplyingScene || !windowService.accessibilityOperational)
                }
            }
            ForEach(Array(report.items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entryLabel(item.entryID, fallbackIndex: index + 1)).font(.caption.weight(.medium)).lineLimit(2)
                        Spacer()
                        Text(item.status.displayName)
                            .font(.caption)
                            .foregroundStyle(item.status.isSuccess ? ArcPalette.secondaryText : ArcPalette.orange)
                    }
                    if let message = item.message {
                        Text(message).font(.caption).foregroundStyle(ArcPalette.secondaryText)
                    }
                }
            }
            if let failure = report.focusFailureMessage {
                Text(failure).font(.caption).foregroundStyle(ArcPalette.orange)
            }
            if report.needsAttention, scene != nil {
                Button(L10n.string(.WindowSettings.scenesReviewBindings)) { editScene(report.sceneID) }
            }
            Text(L10n.string(.WindowSettings.scenesUndoHint)).font(.caption).foregroundStyle(ArcPalette.secondaryText)
        }
    }

    private func entryLabel(_ id: UUID, fallbackIndex: Int) -> String {
        guard let entry = scene?.entries.first(where: { $0.id == id }) else {
            return L10n.string(.WindowSettings.scenesWindowNumber(fallbackIndex))
        }
        return entry.savedTitle.isEmpty ? entry.applicationName : "\(entry.applicationName) — \(entry.savedTitle)"
    }
}
