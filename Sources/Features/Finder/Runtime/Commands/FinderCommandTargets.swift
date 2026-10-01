import ArcKitFinder
import ArcKitPlatform
import Foundation

/// 统一解析命令捕获的选区和目录；不读取实时 Finder 窗口。
struct FinderCommandTargets {
    static func sourceURLs(_ request: FinderCommandRequest) throws -> [URL] {
        let paths = try Self.nonEmptySourcePaths(request)
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func firstSourceURL(_ sourcePaths: [String]) throws -> URL {
        guard sourcePaths.count == 1 else { throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.targetActionSupportsOneItem)) }
        guard let first = sourcePaths.first else { throw FinderCommandExecutionError.emptySelection }
        return URL(fileURLWithPath: first)
    }

    func sourceTargetOrResolvedURLs(_ request: FinderCommandRequest, actionName: String) throws -> [URL] {
        if !request.sourcePaths.isEmpty {
            return try Self.sourceURLs(request)
        }
        if !request.context.selectedPaths.isEmpty {
            return request.context.selectedPaths.map { URL(fileURLWithPath: $0) }
        }
        if let targetPath = request.targetPath, !targetPath.isEmpty {
            return [URL(fileURLWithPath: targetPath)]
        }
        if let targetedPath = request.context.targetedPath, !targetedPath.isEmpty {
            return [URL(fileURLWithPath: targetedPath)]
        }
        let resolvedDirectory = try resolveTargetDirectory(for: request, actionName: actionName)
        ArcKitLog.append("processor resolved target id=\(request.id.uuidString) kind=\(request.kind.rawValue) resolvedTargetPath=\(resolvedDirectory.path) resolutionSource=\(resolvedDirectory.source)")
        return [URL(fileURLWithPath: resolvedDirectory.path)]
    }

    static func nonEmptySourcePaths(_ request: FinderCommandRequest) throws -> [String] {
        guard !request.sourcePaths.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        return request.sourcePaths
    }

    func targetURL(_ request: FinderCommandRequest) throws -> URL {
        URL(fileURLWithPath: try required(request.targetPath, "targetPath"))
    }

    func terminalDirectoryURL(_ request: FinderCommandRequest) throws -> URL {
        guard request.sourcePaths.count <= 1, request.context.selectedPaths.count <= 1 else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.openSelectOneTerminalFolderFile))
        }
        if let first = request.sourcePaths.first {
            return try Self.terminalDirectoryURL(for: URL(fileURLWithPath: first))
        }
        if let targetPath = request.targetPath {
            return try Self.terminalDirectoryURL(for: URL(fileURLWithPath: targetPath))
        }
        if let targetedPath = request.context.targetedPath {
            return try Self.terminalDirectoryURL(for: URL(fileURLWithPath: targetedPath))
        }
        if request.targetResolutionPolicy == .capturedContext,
           let resolved = try resolveCapturedDirectory(request) {
            ArcKitLog.append("processor resolved target id=\(request.id.uuidString) kind=\(request.kind.rawValue) resolvedTargetPath=\(resolved.path) resolutionSource=\(resolved.source)")
            return URL(fileURLWithPath: resolved.path)
        }
        throw FinderCommandExecutionError.missingTargetDirectory(L10n.string(.FinderActions.commandOpenTerminal))
    }

    static func terminalDirectoryURL(for target: URL) throws -> URL {
        // 目录被移走后必须报错，不能因 fileExists 为 false 而悄悄改开父目录。
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values.isDirectory == true && values.isPackage != true ? target : target.deletingLastPathComponent()
    }

    func resolveTargetDirectory(for request: FinderCommandRequest, actionName: String) throws -> FinderResolvedTargetDirectory {
        if let targetPath = request.targetPath, !targetPath.isEmpty {
            return FinderResolvedTargetDirectory(path: targetPath, source: "extension")
        }
        if request.targetResolutionPolicy == .capturedContext {
            if let resolved = try resolveCapturedDirectory(request) {
                return resolved
            }
            throw FinderCommandExecutionError.missingTargetDirectory(actionName)
        }
        throw FinderCommandExecutionError.missingTargetDirectory(actionName)
    }

    private func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw FinderCommandExecutionError.missingValue(name) }
        return value
    }

    private func resolveCapturedDirectory(_ request: FinderCommandRequest) throws -> FinderResolvedTargetDirectory? {
        guard request.context.selectedPaths.count <= 1 else { return nil }
        if let selectedPath = request.context.selectedPaths.first {
            let directory = ShellQuoting.directoryURL(for: URL(fileURLWithPath: selectedPath))
            return try validated(directory.path, source: "contextSelectedPath")
        }
        if let targetedPath = request.context.targetedPath {
            let directory = ShellQuoting.directoryURL(for: URL(fileURLWithPath: targetedPath))
            return try validated(directory.path, source: "contextTargetedPath")
        }
        return nil
    }

    private func validated(_ path: String, source: String) throws -> FinderResolvedTargetDirectory {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FinderCommandExecutionError.targetResolutionFailed(L10n.string(.FinderActions.targetNotDirectory(String(describing: path))))
        }
        return FinderResolvedTargetDirectory(path: path, source: source)
    }
}
