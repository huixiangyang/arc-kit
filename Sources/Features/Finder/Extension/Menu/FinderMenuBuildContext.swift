import ArcKitFinder
import ArcKitPlatform
import FinderSync
import Foundation
import UniformTypeIdentifiers

struct FinderMenuBuildContext {
    var hasSelection: Bool
    var selectedItemCount: Int
    var selectedFileCount: Int
    var selectedFolderCount: Int
    var selectedImageFileCount: Int
    var targetContext: FinderMenuTargetContext

    init(
        hasSelection: Bool,
        selectedItemCount: Int = 0,
        selectedFileCount: Int = 0,
        selectedFolderCount: Int = 0,
        selectedImageFileCount: Int = 0,
        targetKind: FinderMenuTargetKind? = nil,
        hasCurrentDirectory: Bool? = nil
    ) {
        self.hasSelection = hasSelection
        self.selectedItemCount = selectedItemCount
        self.selectedFileCount = selectedFileCount
        self.selectedFolderCount = selectedFolderCount
        self.selectedImageFileCount = selectedImageFileCount
        let resolvedKind = targetKind ?? Self.targetKind(
            hasSelection: hasSelection,
            selectedItemCount: selectedItemCount,
            selectedFileCount: selectedFileCount,
            selectedFolderCount: selectedFolderCount,
            selectedImageFileCount: selectedImageFileCount
        )
        targetContext = FinderMenuTargetContext(kind: resolvedKind, selectedItemCount: selectedItemCount, hasCurrentDirectory: hasCurrentDirectory)
    }

    init(menuKind: FIMenuKind, selectedURLs: [URL], targetedURL: URL?, fileManager: FileManager = .default) {
        // Finder 分栏视图在空白处右键时可能继续返回上一列选中的文件夹。
        // menuKind 是本次点击语义的唯一真值，container 菜单必须彻底忽略陈旧 selection。
        let effectiveSelectedURLs = Self.effectiveSelection(menuKind: menuKind, selectedURLs: selectedURLs, targetedURL: targetedURL)
        var fileCount = 0
        var folderCount = 0
        var imageFileCount = 0
        for url in effectiveSelectedURLs {
            switch Self.itemKind(for: url, fileManager: fileManager) {
            case .file:
                fileCount += 1
                if Self.isImageFile(url) { imageFileCount += 1 }
            case .folder:
                folderCount += 1
            case .unknown:
                break
            }
        }

        self.init(
            hasSelection: !effectiveSelectedURLs.isEmpty,
            selectedItemCount: effectiveSelectedURLs.count,
            selectedFileCount: fileCount,
            selectedFolderCount: folderCount,
            selectedImageFileCount: imageFileCount,
            hasCurrentDirectory: ((menuKind == .contextualMenuForContainer
                || (menuKind == .toolbarItemMenu && effectiveSelectedURLs.isEmpty)) && targetedURL?.isFileURL == true)
                || (effectiveSelectedURLs.count == 1 && folderCount == 1)
        )
    }

    /// 每种入口只消费 Apple 为该入口定义的目标，侧边栏不能沿用窗口选区。
    static func effectiveSelection(menuKind: FIMenuKind, selectedURLs: [URL], targetedURL: URL?) -> [URL] {
        switch menuKind {
        case .contextualMenuForContainer: return []
        case .contextualMenuForSidebar: return targetedURL.map { $0.isFileURL ? [$0] : [] } ?? []
        case .contextualMenuForItems, .toolbarItemMenu: return selectedURLs.filter(\.isFileURL)
        default: return []
        }
    }

    var hasOnlyFiles: Bool {
        hasSelection && selectedItemCount > 0 && selectedFileCount == selectedItemCount
    }

    var hasOnlyFolders: Bool {
        hasSelection && selectedItemCount > 0 && selectedFolderCount == selectedItemCount
    }

    var hasOnlyImageFiles: Bool {
        hasOnlyFiles && selectedImageFileCount == selectedItemCount
    }

    var hasAnyTarget: Bool { targetContext.hasResolvedTarget }
    var canUseCurrentDirectoryTarget: Bool { targetContext.canUseCurrentDirectoryTarget }

    private enum SelectedItemKind {
        case file
        case folder
        case unknown
    }

    private static func itemKind(for url: URL, fileManager: FileManager) -> SelectedItemKind {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]) {
            // App、Pages 等包在 Finder 中是文件，不能展示“解除文件夹”等目录操作。
            if values.isPackage == true { return .file }
            if values.isDirectory == true { return .folder }
            if values.isRegularFile == true { return .file }
        }
        if url.hasDirectoryPath { return .folder }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? .folder : .file
        }
        // Finder 传入的文件 URL 即使暂时无法从沙盒 stat，也仍可按非目录 URL 识别为文件。
        return .file
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func targetKind(
        hasSelection: Bool,
        selectedItemCount: Int,
        selectedFileCount: Int,
        selectedFolderCount: Int,
        selectedImageFileCount: Int
    ) -> FinderMenuTargetKind {
        guard hasSelection else { return .blank }
        if selectedFolderCount == selectedItemCount { return .folders }
        if selectedFileCount == selectedItemCount {
            return selectedImageFileCount == selectedItemCount ? .images : .files
        }
        return .mixed
    }
}
