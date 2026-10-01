import ArcKitPlatform
import Foundation

/// 文件整理操作以选中项的父目录为上下文；选中的目录本身不是输出目录。
enum FinderFileSelection {
    static func commonParent(of urls: [URL], fileManager: FileManager) throws -> URL {
        guard let first = urls.first else { throw FinderCommandExecutionError.emptySelection }
        let parent = first.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var paths = Set<String>()
        for url in urls {
            let itemParent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard itemParent == parent, url.path != "/" else {
                throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.selectionAllSelectedItems))
            }
            guard paths.insert(itemParent.appendingPathComponent(url.lastPathComponent).path).inserted else {
                throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.transferDuplicateSelectedItem(String(describing: url.path))))
            }
            _ = try fileManager.attributesOfItem(atPath: url.path)
        }
        return parent
    }
}
