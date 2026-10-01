import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit

/// 目录选择必须由常驻 Agent 承载；Finder Sync 扩展没有可靠的前台模态窗口生命周期。
@MainActor
enum FinderDirectoryTransferPrompt {
    static func present(
        mode: FinderFileTransferMode,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        FinderProcessAppKitLifecycle.ensureReady(activate: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.string(.FinderActions.transferPromptChooseLocation(String(describing: mode.actionTitle)))
        panel.message = L10n.string(.FinderActions.transferPromptChooseDestinationFolder(String(describing: mode.actionTitle)))
        panel.prompt = L10n.string(.Common.choose)

        // 非阻塞展示，避免 Agent 主线程被 `runModal` 占住后无法响应辅助功能和系统事件。
        panel.begin { response in
            Task { @MainActor in
                completion(response == .OK ? panel.url?.path : nil)
            }
        }
    }
}
