import ArcKitFinder
import ArcKitPlatform
import Foundation

public struct NewFileCreationResult: Equatable, Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

public enum NewFileCreationError: LocalizedError {
    case templateNotFound(String)
    case targetIsNotDirectory(String)
    case targetIsNotWritable(String)
    case templateSourceMissing(String)
    case unsupportedTemplate(String)

    public var errorDescription: String? {
        switch self {
        case let .templateNotFound(templateID):
            L10n.string(.FinderActions.newFileNewFileTemplateMissing(String(describing: templateID)))
        case let .targetIsNotDirectory(path):
            L10n.string(.FinderActions.newFileInvalidDestination(String(describing: path)))
        case let .targetIsNotWritable(path):
            L10n.string(.FinderActions.newFileDestinationNotWritable(String(describing: path)))
        case let .templateSourceMissing(templateID):
            L10n.string(.FinderActions.newFileTemplateSourceMissingUnreadableChoose(String(describing: templateID)))
        case let .unsupportedTemplate(fileExtension):
            L10n.string(.FinderActions.newFileProtectedDestination(String(describing: fileExtension)))
        }
    }
}

public struct NewFileCreationService {
    private let fileManager: FileManager
    private let sourceResolver: NewFileTemplateSourceResolver

    public init(
        fileManager: FileManager = .default,
        sourceResolver: NewFileTemplateSourceResolver = NewFileTemplateSourceResolver()
    ) {
        self.fileManager = fileManager
        self.sourceResolver = sourceResolver
    }

    public func createFile(templateID: String, directoryPath: String, settings: FinderRuntimeSettings) throws -> NewFileCreationResult {
        guard let template = settings.menuConfiguration.fileTemplates.first(where: { $0.id == templateID }) else {
            throw NewFileCreationError.templateNotFound(templateID)
        }

        let directory = ShellQuoting.directoryURL(for: URL(fileURLWithPath: directoryPath))
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NewFileCreationError.targetIsNotDirectory(directory.path)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw NewFileCreationError.targetIsNotWritable(directory.path)
        }

        let fileURL = uniqueFileURL(baseURL: directory.appendingPathComponent(template.defaultFileName))
        let fileExtension = template.normalizedExtension.lowercased()
        guard let source = template.resolvedTemplateSource,
              let sourceURL = sourceResolver.templateURL(for: source) else {
            ArcKitLog.append("new file creation type=missingTemplateSource templateID=\(template.id) extension=\(fileExtension) source=\(template.resolvedTemplateSource?.diagnosticDescription ?? "-")")
            throw NewFileCreationError.templateSourceMissing(template.id)
        }
        if template.isUnsupportedComplexDocument {
            ArcKitLog.append("new file creation type=unsupportedTemplate extension=\(fileExtension) target=\(directory.path)")
            throw NewFileCreationError.unsupportedTemplate(fileExtension)
        }
        try fileManager.copyItem(at: sourceURL, to: fileURL)
        ArcKitLog.append("new file creation type=templateCopy path=\(fileURL.path) extension=\(fileExtension) source=\(source.diagnosticDescription)")

        if fileExtension == "sh" {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }

        return NewFileCreationResult(fileURL: fileURL)
    }

    private func uniqueFileURL(baseURL: URL) -> URL {
        if !fileManager.fileExists(atPath: baseURL.path) { return baseURL }
        let ext = baseURL.pathExtension
        let baseName = baseURL.deletingPathExtension().lastPathComponent
        var index = 2
        while index <= 1024 {
            let name = ext.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(ext)"
            let candidate = baseURL.deletingLastPathComponent().appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        // 所有名称均被占用时，追加时间戳兜底防死循环
        let fallbackName: String
        if ext.isEmpty {
            fallbackName = "\(baseName) \(Int(Date().timeIntervalSince1970))"
        } else {
            fallbackName = "\(baseName) \(Int(Date().timeIntervalSince1970)).\(ext)"
        }
        return baseURL.deletingLastPathComponent().appendingPathComponent(fallbackName)
    }

}
