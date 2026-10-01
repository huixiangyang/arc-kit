import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import UniformTypeIdentifiers

/// 文件夹图标选图属于单次文件动作，生产链路只在 Operation Worker 内展示。
@MainActor
enum FinderFolderIconPrompt {
    static func present() -> String? {
        ArcKitLog.append("processor setFolderIcon imagePicker begin")
        let application = FinderProcessAppKitLifecycle.ensureReady()
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        defer { application.setActivationPolicy(previousPolicy) }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.message = L10n.string(.FinderActions.folderIconChooseImageFolderIcon)
        panel.prompt = L10n.string(.FinderActions.folderIconSetIcon)
        panel.level = .floating
        panel.center()
        guard panel.runModal() == .OK, let url = panel.url else {
            ArcKitLog.append("processor setFolderIcon imagePicker cancelled")
            return nil
        }
        ArcKitLog.append("processor setFolderIcon imagePicker selected path=\(url.path)")
        return url.path
    }
}
