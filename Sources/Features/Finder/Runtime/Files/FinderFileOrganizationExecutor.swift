import ArcKitPlatform
import ArcKitFinder
import Darwin
import Foundation

/// 文件整理复用传输计划与回滚，禁止通过 mv 隐式覆盖同名项目。
struct FinderFileOrganizationExecutor {
    let fileManager: FileManager
    let transfer: FinderFileTransferExecutor

    init(fileManager: FileManager = .default, transfer: FinderFileTransferExecutor? = nil) {
        self.fileManager = fileManager
        self.transfer = transfer ?? FinderFileTransferExecutor(fileManager: fileManager)
    }

    func group(_ urls: [URL], folderName: String) throws -> URL {
        let parent = try FinderFileSelection.commonParent(of: urls, fileManager: fileManager)
        guard !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              folderName != ".", folderName != "..", !folderName.contains("/"),
              !folderName.contains(":"), !folderName.contains("\0") else {
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.organizeInvalidTargetFolderName))
        }
        let destination = parent.appendingPathComponent(folderName, isDirectory: true)
        // 已有目录也不能合并进入，避免改变未选中的文件；调用者需换一个名称。
        guard Darwin.mkdir(destination.path, 0o755) == 0 else {
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.organizeFolderCreationFailed(String(describing: destination.path))))
        }
        do {
            let plan = try FinderFileTransferPlanner(fileManager: fileManager).makePlan(
                sourcePaths: urls.map(\.path), destinationDirectoryPath: destination.path, mode: .move
            )
            _ = try transfer.execute(plan)
            return destination
        } catch {
            // 只清理本次创建且已回滚为空的目录，保留无法恢复的项目及其错误证据。
            guard Darwin.rmdir(destination.path) == 0 else {
                throw FinderFileTransferError.rollbackFailed(
                    action: L10n.string(.FinderActions.commandGroupInFolder), original: error.localizedDescription,
                    rollback: L10n.string(.FinderActions.organizeTargetFolderPreservedInspection(String(describing: destination.path)))
                )
            }
            throw error
        }
    }

    func flatten(_ urls: [URL]) throws -> [URL] {
        let parent = try FinderFileSelection.commonParent(of: urls, fileManager: fileManager)
        var children: [URL] = []
        for url in urls {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  try url.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.organizeRegularFolderRequired(String(describing: url.path))))
            }
            children += try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        // 整批计算落点，多个文件夹里的同名子项也必须提前避让。
        let plan = try children.isEmpty
            ? FinderFileTransferPlan(mode: .move, destinationDirectory: parent, items: [])
            : FinderFileTransferPlanner(fileManager: fileManager).makePlan(
                sourcePaths: children.map(\.path), destinationDirectoryPath: parent.path, mode: .move
            )
        return try transfer.execute(plan, removingEmptyDirectories: urls)
    }
}
