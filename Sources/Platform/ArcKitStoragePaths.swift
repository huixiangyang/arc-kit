import Darwin
import Foundation

/// 所有非沙盒组件共用的数据根。构造路径无副作用，首次打开存储时才创建。
public struct ArcKitStoragePaths: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }
    public static let current: Self = {
        #if DEBUG
        // Debug 永远不能意外写入正式库；Host 从同一源码位置推导相同根。
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Self(root: source.appendingPathComponent(".build/ui-debug/data"))
        #else
        return Self(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc-kit"))
        #endif
    }()
    public var database: URL { root.appendingPathComponent("app.sqlite") }
    public var media: URL { root.appendingPathComponent("assets/media") }
    public var templates: URL { root.appendingPathComponent("assets/templates") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var runtime: URL { root.appendingPathComponent("runtime") }
    public var cache: URL { root.appendingPathComponent("cache") }
    public var thumbnails: URL { cache.appendingPathComponent("thumbnails") }
    public var remote: URL { cache.appendingPathComponent("remote") }
    public var updates: URL { cache.appendingPathComponent("updates") }
    public var temporary: URL { root.appendingPathComponent("tmp") }
    public var backups: URL { root.appendingPathComponent("backups") }
    public var diagnostics: URL { root.appendingPathComponent("diagnostics") }
    public var owner: URL { runtime.appendingPathComponent("owner.json") }
    public var receipts: URL { runtime.appendingPathComponent("finder-receipts.json") }
    public func lock(_ kind: ArcKitProcessKind) -> URL { runtime.appendingPathComponent("\(kind.rawValue).lock") }

    public func prepare() throws {
        let fm = FileManager.default
        // 不允许根或已存在的受管子目录经符号链接重定向；不支持云盘和网络卷。
        let resolved = root.resolvingSymlinksInPath().path
        guard resolved == root.path, !resolved.contains("/Library/Mobile Documents/"),
              !resolved.contains("/Library/CloudStorage/") else { throw StoragePathError.unsafePath(root.path) }
        try Self.secureDirectory(root)
        let values = try root.resourceValues(forKeys: [.volumeIsLocalKey])
        guard values.volumeIsLocal == true else { throw StoragePathError.unsafePath(root.path) }
        for path in [media, templates, logs, runtime, thumbnails, remote, updates, temporary, backups, diagnostics] {
            try Self.secureDirectory(path)
        }
        for path in [database, owner, receipts] where fm.fileExists(atPath: path.path) {
            try Self.secureFile(path)
        }
    }

    public static func secureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else { throw StoragePathError.unsafePath(url.path) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw StoragePathError.unsafePath(url.path) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func validateFile(_ url: URL) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else { throw StoragePathError.unsafePath(url.path) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw StoragePathError.unsafePath(url.path) }
    }

    public static func secureFile(_ url: URL) throws {
        try validateFile(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 导入的模板可能是文件包；逐项拒绝链接并收紧权限，不将目录当普通文件。
    public static func secureTree(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw StoragePathError.unsafePath(url.path) }
        if values.isDirectory == true {
            try secureDirectory(url)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try secureTree(child) }
        } else { try secureFile(url) }
    }

    public static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    public func makeTemporaryDirectory() throws -> URL {
        try Self.secureDirectory(temporary)
        let directory = temporary.appendingPathComponent(UUID().uuidString)
        try Self.secureDirectory(directory)
        // 清理器只删除能确认所属进程已经结束的旧任务。
        let owner = try RuntimeHostSession(windowEnabled: false, mouseEnabled: false, finderEnabled: false)
        try owner.save(to: directory.appendingPathComponent("owner.json"))
        return directory
    }
}

public enum StoragePathError: LocalizedError {
    case unsafeRoot
    case unsafePath(String)
    public var errorDescription: String? {
        let reason = L10n.string(.Platform.storageDataPathLocal)
        switch self { case .unsafeRoot: return reason; case .unsafePath(let path): return reason + L10n.string(.Platform.storagePath) + path }
    }
}
