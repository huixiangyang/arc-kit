import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Darwin
import Foundation

struct FinderImageCommandExecutor {
    let fileManager: FileManager
    let process: FinderProcessRunner
    let folderIconImagePicker: () -> String?
    let folderIconSetter: (NSImage?, String) -> Bool
    let folderCustomIconState: (String) -> Bool?
    private var outputWriter: FinderGeneratedFileWriter { FinderGeneratedFileWriter(fileManager: fileManager) }
    private static let imageFormats = ["png", "jpg", "bmp", "tiff"]

    init(
        fileManager: FileManager = .default,
        process: FinderProcessRunner = FinderProcessRunner(),
        folderIconImagePicker: @escaping () -> String? = { nil },
        folderIconSetter: ((NSImage?, String) -> Bool)? = nil,
        folderCustomIconState: ((String) -> Bool?)? = nil
    ) {
        self.fileManager = fileManager
        self.process = process
        self.folderIconImagePicker = folderIconImagePicker
        self.folderIconSetter = folderIconSetter ?? Self.defaultFolderIconSetter
        self.folderCustomIconState = folderCustomIconState ?? Self.defaultFolderCustomIconState
    }

    func execute(_ request: FinderCommandRequest) throws -> FinderCommandExecutionResult? {
        switch request.payload {
        case let .setFolderIcon(payload):
            let sourcePaths = try FinderCommandTargets.nonEmptySourcePaths(request)
            try validateFolderIconTargetPaths(sourcePaths)
            guard let imagePath = payload.imagePath ?? folderIconImagePicker() else {
                ArcKitLog.append("processor setFolderIcon cancelled imagePicker")
                return FinderCommandExecutionResult(userMessage: L10n.string(.FinderActions.imageFolderIconChangeCancelled))
            }
            ArcKitLog.append("processor setFolderIcon imagePath=\(imagePath) targetCount=\(sourcePaths.count)")
            try setFolderIcon(imagePath: imagePath, paths: sourcePaths)
        case .restoreFolderIcon:
            let sourcePaths = try FinderCommandTargets.nonEmptySourcePaths(request)
            try validateFolderIconTargetPaths(sourcePaths)
            try restoreFolderIcon(paths: sourcePaths)
        case let .extractIcon(payload):
            let url = try FinderCommandTargets.firstSourceURL(FinderCommandTargets.nonEmptySourcePaths(request))
            let outputDirectory = payload.outputDirectoryPath.map(URL.init(fileURLWithPath:))
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let destination = try outputWriter.write(
                beside: outputDirectory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-icon.png")
            ) { try extractIcon(from: url, to: $0) }
            return FinderCommandExecutionResult(createdPaths: [destination.path], userMessage: L10n.string(.FinderActions.imageIconExtracted))
        case let .convertImage(payload):
            let format = payload.format.lowercased()
            guard Self.imageFormats.contains(format) else {
                throw FinderCommandExecutionError.unsupportedImageFormat(format)
            }
            var outputs: [String] = []
            do {
                for url in try FinderCommandTargets.sourceURLs(request) {
                    let output = try outputWriter.write(beside: url.deletingPathExtension().appendingPathExtension(format)) { staged in
                        try process.run(executable: "/usr/bin/sips", arguments: [
                            "-s", "format", format == "jpg" ? "jpeg" : format, url.path, "--out", staged.path,
                        ])
                    }
                    outputs.append(output.path)
                }
            } catch {
                guard !outputs.isEmpty else { throw error }
                throw FinderCommandExecutionError.partiallyCompleted(action: L10n.string(.FinderActions.imageImageConversion), completedPaths: outputs, reason: error.localizedDescription)
            }
            return FinderCommandExecutionResult(createdPaths: outputs, userMessage: L10n.string(.FinderActions.imagesConvertedCount(Int(outputs.count))))
        default:
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.imageImageIconExecutorReceivedUnexpected(String(describing: request.kind.rawValue))))
        }
        return nil
    }

    private func setFolderIcon(imagePath: String, paths: [String]) throws {
        guard let image = NSImage(contentsOfFile: imagePath) else {
            throw FinderCommandExecutionError.imageLoadFailed(imagePath)
        }
        for path in paths {
            guard folderIconSetter(image, path) else {
                throw FinderCommandExecutionError.commandFailed("setIcon \(path)")
            }
            try verifyFolderCustomIcon(path: path, expected: true)
        }
    }

    private func restoreFolderIcon(paths: [String]) throws {
        for path in paths {
            guard folderIconSetter(nil, path) else {
                throw FinderCommandExecutionError.commandFailed("restoreIcon \(path)")
            }
            try verifyFolderCustomIcon(path: path, expected: false)
        }
    }

    private func verifyFolderCustomIcon(path: String, expected: Bool) throws {
        guard let hasCustomIcon = folderCustomIconState(path) else {
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.imageIconReadbackFailed(String(describing: path))))
        }
        guard hasCustomIcon == expected else {
            let action = expected ? L10n.string(.FinderActions.commandSetFolderIcon) : L10n.string(.FinderActions.commandRestoreFolderIcon)
            throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.imageUnconfirmed(String(describing: action), String(describing: path))))
        }
    }

    private func validateFolderIconTargetPaths(_ paths: [String]) throws {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FinderCommandExecutionError.operationVerificationFailed(L10n.string(.FinderActions.imageFolderIconsRequireRealFolders(String(describing: path))))
            }
        }
    }

    private func extractIcon(from sourceURL: URL, to destinationURL: URL) throws {
        let icon = NSWorkspace.shared.icon(forFile: sourceURL.path)
        icon.size = NSSize(width: 512, height: 512)
        guard let tiff = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FinderCommandExecutionError.imageLoadFailed(sourceURL.path)
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func defaultFolderIconSetter(image: NSImage?, path: String) -> Bool {
        NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }

    private static func defaultFolderCustomIconState(path: String) -> Bool? {
        let attributeName = "com.apple.FinderInfo"
        let length = getxattr(path, attributeName, nil, 0, 0, 0)
        if length < 0 {
            return errno == ENOATTR ? false : nil
        }
        guard length >= 10 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: length)
        let readLength = getxattr(path, attributeName, &bytes, bytes.count, 0, 0)
        guard readLength >= 10 else {
            return nil
        }
        // FinderInfo 前 16 字节是 FInfo，offset 8~9 为 big-endian finderFlags；0x0400 表示自定义图标。
        let finderFlags = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        return (finderFlags & 0x0400) != 0
    }
}
