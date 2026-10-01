import Foundation
import Darwin

public enum FinderObservedDirectoryValidationMode: Sendable {
    case configuration
    case extensionRuntime
}

public enum FinderUserHomeDirectoryResolver {
    public static func resolve(fileManager: FileManager = .default) -> URL {
        resolve(
            fileManagerHome: fileManager.homeDirectoryForCurrentUser,
            accountHomePath: currentAccountHomePath()
        )
    }

    public static func resolve(fileManagerHome: URL, accountHomePath: String?) -> URL {
        guard let accountHomePath else { return fileManagerHome }
        let standardized = (accountHomePath as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/", standardized != "/var/empty" else {
            return fileManagerHome
        }
        return URL(fileURLWithPath: standardized, isDirectory: true)
    }

    private static func currentAccountHomePath() -> String? {
        guard let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_dir else {
            return nil
        }
        return String(cString: pointer)
    }
}

public enum FinderObservedDirectoryBuilder {
    /// 保留 iCloud Drive 的显式观察根，供 Finder 提供工具栏目标；这不保证云盘右键回调。
    /// 这里只包含用户可见的 Drive 文档，不开放整个 Mobile Documents 或应用容器。
    public static func iCloudDriveDirectory(userHomeDirectory: URL? = nil) -> URL {
        (userHomeDirectory ?? FinderUserHomeDirectoryResolver.resolve())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private static let protectedAbsolutePaths: Set<String> = [
        "/",
        "/System",
        "/Library",
        "/private",
        "/var",
        "/etc",
        "/bin",
        "/sbin",
        "/usr"
    ]

    public static func defaultObservedDirectoryPaths(
        fileManager: FileManager = .default,
        validationMode: FinderObservedDirectoryValidationMode = .configuration,
        userHomeDirectory: URL? = nil
    ) -> [String] {
        let resolvedHomeDirectory = userHomeDirectory ?? FinderUserHomeDirectoryResolver.resolve(fileManager: fileManager)
        return sanitizedObservedDirectoryPaths(
            [resolvedHomeDirectory.path, iCloudDriveDirectory(userHomeDirectory: resolvedHomeDirectory).path],
            fileManager: fileManager,
            validationMode: validationMode,
            userHomeDirectory: resolvedHomeDirectory
        )
    }

    public static func observedDirectoryPaths(
        settings: FinderRuntimeSettings,
        fileManager: FileManager = .default,
        validationMode: FinderObservedDirectoryValidationMode = .configuration,
        userHomeDirectory: URL? = nil
    ) -> [String] {
        var paths = defaultObservedDirectoryPaths(
            fileManager: fileManager,
            validationMode: validationMode,
            userHomeDirectory: userHomeDirectory
        )
        func append(_ path: String) {
            let normalized = (path as NSString).expandingTildeInPath
            guard !normalized.isEmpty, !paths.contains(normalized) else { return }
            paths.append(normalized)
        }

        let resolvedHomeDirectory = userHomeDirectory ?? FinderUserHomeDirectoryResolver.resolve(fileManager: fileManager)
        // Home 和 iCloud Drive 分别注册；额外目录用于外置卷等其他工作位置。
        for rawPath in settings.menuConfiguration.additionalObservedDirectoryPaths {
            append(rawPath)
        }

        return sanitizedObservedDirectoryPaths(
            paths,
            fileManager: fileManager,
            validationMode: validationMode,
            userHomeDirectory: resolvedHomeDirectory
        )
    }

    public static func sanitizedObservedDirectoryPaths(
        _ paths: [String],
        fileManager: FileManager = .default,
        validationMode: FinderObservedDirectoryValidationMode = .configuration,
        userHomeDirectory: URL? = nil
    ) -> [String] {
        let resolvedHomeDirectory = userHomeDirectory ?? FinderUserHomeDirectoryResolver.resolve(fileManager: fileManager)
        let cloudRoot = standardizedPath(iCloudDriveDirectory(userHomeDirectory: resolvedHomeDirectory).path)
        func covers(_ ancestor: String, _ path: String) -> Bool {
            // 保留云盘的显式注册，不把它合并成普通 Home；是否分发回调仍由 Finder 决定。
            if contains(path, in: cloudRoot) && !contains(ancestor, in: cloudRoot) { return false }
            return contains(path, in: ancestor)
        }
        var sanitized: [String] = []
        for rawPath in paths {
            let path = standardizedPath(rawPath)
            guard isSafeObservedDirectoryPath(
                path,
                fileManager: fileManager,
                userHomeDirectory: resolvedHomeDirectory
            ) else { continue }
            if validationMode == .configuration {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            }
            // 同一观察边界内合并父子目录，跨 Home / iCloud 边界不得合并。
            guard !sanitized.contains(where: { covers($0, path) }) else { continue }
            sanitized.removeAll(where: { covers(path, $0) })
            sanitized.append(path)
        }
        return sanitized
    }

    public static func isSafeObservedDirectoryPath(
        _ rawPath: String,
        fileManager: FileManager = .default,
        userHomeDirectory: URL? = nil
    ) -> Bool {
        let path = standardizedPath(rawPath)
        guard path.hasPrefix("/") else { return false }
        let home = standardizedPath(
            (userHomeDirectory ?? FinderUserHomeDirectoryResolver.resolve(fileManager: fileManager)).path
        )
        if protectedAbsolutePaths.contains(path) { return false }
        let cloudRoot = standardizedPath(iCloudDriveDirectory(userHomeDirectory: URL(fileURLWithPath: home)).path)
        if contains(path, in: "\(home)/Library") && !contains(path, in: cloudRoot) { return false }
        if path == "/Applications" || path.hasPrefix("/Applications/") { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix("/private/") { return false }
        if path.hasPrefix("/var/") || path.hasPrefix("/etc/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") || path.hasPrefix("/usr/") { return false }
        return true
    }

    private static func standardizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }

    public static func urls(from paths: [String]) -> Set<URL> {
        Set(
            sanitizedObservedDirectoryPaths(paths, validationMode: .extensionRuntime)
                .map { URL(fileURLWithPath: $0) }
        )
    }
}
