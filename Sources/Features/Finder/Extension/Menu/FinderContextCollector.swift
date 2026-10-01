import ArcKitFinder
import ArcKitPlatform
import FinderSync
import Foundation

/// Finder 扩展侧上下文采集器。
///
/// 只负责记录菜单生成时 Finder 给出的目标；动作回调消费对应菜单实例的快照，
/// 不做业务判断、不创建文件、不启动 App。
enum FinderContextCollector {
    struct ActionTargetSnapshot: Equatable, Sendable {
        var sourcePaths: [String]
        var targetPath: String?
        var currentDirectoryPath: String?
        var targetKind: FinderMenuTargetKind
        var targetResolutionPolicy: FinderTargetResolutionPolicy
        var needsHostTargetResolution: Bool
        var context: FinderActionContext
    }

    static var selectedURLs: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    static var targetedURL: URL? {
        FIFinderSyncController.default().targetedURL()
    }

    static func makeActionTarget(
        selectedPaths: [String],
        targetedPath: String?,
        menuKind: FIMenuKind? = nil,
        targetKind: FinderMenuTargetKind? = nil
    ) -> ActionTargetSnapshot {
        let kind = menuKind ?? (selectedPaths.isEmpty ? .contextualMenuForContainer : .contextualMenuForItems)
        let effectiveSelectedPaths = FinderMenuBuildContext.effectiveSelection(
            menuKind: kind,
            selectedURLs: selectedPaths.map { URL(fileURLWithPath: $0) },
            targetedURL: targetedPath.map { URL(fileURLWithPath: $0) }
        ).map(\.path)
        // 工具栏优先消费当前选区；无选区时才使用 Finder 给出的目录，不能转而猜前台窗口。
        let usesContainer = kind == .contextualMenuForContainer
            || (kind == .toolbarItemMenu && effectiveSelectedPaths.isEmpty)
        let targetPath = usesContainer ? targetedPath : nil
        let resolvedTargetKind = targetKind ?? FinderMenuBuildContext(
            menuKind: kind,
            selectedURLs: effectiveSelectedPaths.map { URL(fileURLWithPath: $0) },
            targetedURL: targetedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ).targetContext.kind
        let currentDirectoryPath: String?
        if effectiveSelectedPaths.count == 1, let firstSelectedPath = effectiveSelectedPaths.first {
            switch resolvedTargetKind {
            case .folders:
                // Finder 已确认这是文件夹选择，不能再被沙盒内的 fileExists 误判为文件。
                currentDirectoryPath = firstSelectedPath
            case .files, .images:
                currentDirectoryPath = URL(fileURLWithPath: firstSelectedPath).deletingLastPathComponent().path
            case .blank, .mixed:
                currentDirectoryPath = nil
            }
        } else if let targetPath {
            // container 或无选区工具栏的 targetedURL 来自本次菜单回调。
            currentDirectoryPath = targetPath
        } else {
            currentDirectoryPath = nil
        }
        // 缺失目标时失败关闭，禁止异步去猜另一个 Finder 窗口。
        let needsHostTargetResolution = false
        let targetResolutionPolicy: FinderTargetResolutionPolicy = .extensionTargetOnly
        let context = FinderActionContext(
            selectedPaths: effectiveSelectedPaths,
            targetedPath: targetPath,
            menuKind: menuKind.map { String($0.rawValue) },
            needsHostTargetResolution: needsHostTargetResolution
        )
        return ActionTargetSnapshot(
            sourcePaths: effectiveSelectedPaths,
            targetPath: targetPath,
            currentDirectoryPath: currentDirectoryPath,
            targetKind: resolvedTargetKind,
            targetResolutionPolicy: targetResolutionPolicy,
            needsHostTargetResolution: needsHostTargetResolution,
            context: context
        )
    }

}
