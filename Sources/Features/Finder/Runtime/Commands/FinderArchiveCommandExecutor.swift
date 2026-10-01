import ArcKitPlatform
import Darwin
import Foundation

struct FinderArchiveCommandExecutor {
    let fileManager: FileManager
    let process: FinderProcessRunner

    func archive(_ urls: [URL]) throws -> URL {
        let parent = try FinderFileSelection.commonParent(of: urls, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: urls[0].path)
        let firstName = attributes[.type] as? FileAttributeType == .typeDirectory
            ? urls[0].lastPathComponent : urls[0].deletingPathExtension().lastPathComponent
        let name = urls.count == 1 ? firstName : "Archive"
        return try FinderGeneratedFileWriter(fileManager: fileManager).write(
            beside: parent.appendingPathComponent(name + ".zip")
        ) { output in
            // ditto 的 ZIP 会保存 AppleDouble 元数据，但只接受一个源，且会跟随入口符号链接。
            // 多选或链接先归入临时容器；容器本身不进入 ZIP，链接保留为目录项。
            let needsStaging = urls.count > 1 || attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let source: URL
            if needsStaging {
                source = output.deletingLastPathComponent().appendingPathComponent("items", isDirectory: true)
                try fileManager.createDirectory(at: source, withIntermediateDirectories: false)
                do {
                    for url in urls {
                        let destination = source.appendingPathComponent(url.lastPathComponent)
                        // APFS 优先写时复制；不支持 clone 的卷回退为普通复制，ACL 与扩展属性一并保留。
                        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
                        guard copyfile(url.path, destination.path, nil, flags) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                    try compress(source, to: output, keepParent: false)
                } catch {
                    let original = error
                    do { try removeStaging(source) }
                    catch {
                        throw FinderCommandExecutionError.operationVerificationFailed("\(original.localizedDescription)；\(error.localizedDescription)")
                    }
                    throw original
                }
                try removeStaging(source)
            } else {
                source = urls[0]
                try compress(source, to: output, keepParent: true)
            }
        }
    }

    private func compress(_ source: URL, to output: URL, keepParent: Bool) throws {
        try process.run(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--rsrc", "--extattr", "--acl", "--sequesterRsrc"]
                + (keepParent ? ["--keepParent"] : []) + [source.path, output.path]
        )
    }

    private func removeStaging(_ directory: URL) throws {
        do {
            try prepareForRemoval(directory)
            try fileManager.removeItem(at: directory)
        } catch {
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.archiveCleanupFailed(String(describing: directory.path), String(describing: error.localizedDescription))))
        }
    }

    private func prepareForRemoval(_ url: URL) throws {
        // 副本会继承用户锁定标记；只解锁本次私有暂存树，lstat/lchflags 不跟随链接。
        var status = stat()
        guard lstat(url.path, &status) == 0,
              lchflags(url.path, status.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return }
        guard chmod(url.path, status.st_mode | S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try prepareForRemoval(child)
        }
    }
}
