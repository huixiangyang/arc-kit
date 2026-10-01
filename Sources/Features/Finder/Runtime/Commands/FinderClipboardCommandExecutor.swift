import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation

/// 只生成剪贴板结果；真实剪贴板写入仍由主线程的命令处理器负责。
struct FinderClipboardCommandExecutor {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func execute(_ request: FinderCommandRequest, targets: FinderCommandTargets) throws -> FinderCommandExecutionResult? {
        switch request.payload {
        case .copyPaths:
            return FinderCommandExecutionResult(
                clipboardText: try selectionText(urls: targets.sourceTargetOrResolvedURLs(request, actionName: L10n.string(.FinderActions.commandCopyPath)), component: \.path),
                clipboardResultKind: .paths
            )
        case .copyFileNames:
            return FinderCommandExecutionResult(
                clipboardText: try selectionText(urls: targets.sourceTargetOrResolvedURLs(request, actionName: L10n.string(.FinderActions.menuCopyFilename)), component: \.lastPathComponent),
                clipboardResultKind: .fileNames
            )
        case .copyFileInfo:
            return FinderCommandExecutionResult(
                clipboardText: try fileInfoText(urls: targets.sourceTargetOrResolvedURLs(request, actionName: L10n.string(.FinderActions.commandCopyFileInfo))),
                clipboardResultKind: .fileInfo
            )
        case let .copyHash(payload):
            return FinderCommandExecutionResult(
                clipboardText: try hashText(urls: payload.sourcePaths.map { URL(fileURLWithPath: $0) }, algorithm: payload.algorithm),
                clipboardResultKind: .hash
            )
        case let .copyPickedColor(payload):
            return FinderCommandExecutionResult(
                clipboardText: try pickedColorText(url: try FinderCommandTargets.firstSourceURL(payload.sourcePaths), includeHash: payload.includeHash),
                clipboardResultKind: .color
            )
        default:
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.clipboardClipboardExecutorReceivedUnexpectedCommand(String(describing: request.kind.rawValue))))
        }
    }

    private func selectionText(urls: [URL], component: KeyPath<URL, String>) throws -> String {
        guard !urls.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        return urls.map { $0[keyPath: component] }.joined(separator: "\n")
    }

    private func fileInfoText(urls: [URL]) throws -> String {
        guard !urls.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        return urls.map { url in
            var out = [L10n.string(.FinderActions.clipboardName(String(describing: url.lastPathComponent))), L10n.string(.FinderActions.clipboardPath(String(describing: url.path)))]
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path) {
                if let type = attrs[.type] { out.append(L10n.string(.FinderActions.clipboardType(String(describing: type)))) }
                if let size = attrs[.size] as? NSNumber { out.append(L10n.string(.FinderActions.clipboardSizeBytes(String(describing: size.int64Value)))) }
                if let modified = attrs[.modificationDate] as? Date { out.append(L10n.string(.FinderActions.clipboardModified(String(describing: modified)))) }
            }
            return out.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func hashText(urls: [URL], algorithm: FileHashAlgorithm) throws -> String {
        guard !urls.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        return try urls.map { url in
            return "\(url.lastPathComponent): \(try algorithm.hexDigest(forFileAt: url))"
        }.joined(separator: "\n")
    }

    private func pickedColorText(url: URL, includeHash: Bool) throws -> String {
        guard let image = NSImage(contentsOf: url), let color = image.centerPixelColor else {
            throw FinderCommandExecutionError.imageLoadFailed(url.path)
        }
        return color.hexString(includeHash: includeHash)
    }
}

private extension NSImage {
    var centerPixelColor: NSColor? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else { return nil }
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    }
}

private extension NSColor {
    func hexString(includeHash: Bool) -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return includeHash ? "#000000" : "000000" }
        let value = String(
            format: "%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
        return includeHash ? "#\(value)" : value
    }
}
