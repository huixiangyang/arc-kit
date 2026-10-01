import ArcKitPlatform
import Foundation

public enum NewFileTemplateImportError: LocalizedError, Equatable {
    case missingFileExtension
    case invalidDisplayName

    public var errorDescription: String? {
        switch self {
        case .missingFileExtension:
            L10n.string(.Finder.templateTemplateFilesExplicitExtension)
        case .invalidDisplayName:
            L10n.string(.Finder.templateTemplateNameNonemptyContainMissing)
        }
    }
}

public struct BuiltInNewFileTemplateManifestEntry: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var fileExtension: String
    public var resourceName: String
    public var sortOrder: Int
    public var preferredBundleIDs: [String]
}

public enum BuiltInNewFileTemplateManifest {
    public static let resourceDirectoryName = "NewFileTemplates"
    public static let manifestFileName = "manifest.json"

    public static let entries: [BuiltInNewFileTemplateManifestEntry] = [
        .init(id: "text", displayName: "Text", fileExtension: "txt", resourceName: "text.txt", sortOrder: 0, preferredBundleIDs: ["com.apple.TextEdit"]),
        .init(id: "richText", displayName: "Rich", fileExtension: "rtf", resourceName: "richText.rtf", sortOrder: 1, preferredBundleIDs: ["com.apple.TextEdit"]),
        .init(id: "json", displayName: "Json", fileExtension: "json", resourceName: "json.json", sortOrder: 2, preferredBundleIDs: []),
        .init(id: "word", displayName: "Word", fileExtension: "docx", resourceName: "word.docx", sortOrder: 3, preferredBundleIDs: ["com.microsoft.Word"]),
        .init(id: "excel", displayName: "Excel", fileExtension: "xlsx", resourceName: "excel.xlsx", sortOrder: 4, preferredBundleIDs: ["com.microsoft.Excel"]),
        .init(id: "powerPoint", displayName: "PowerPoint", fileExtension: "pptx", resourceName: "powerPoint.pptx", sortOrder: 5, preferredBundleIDs: ["com.microsoft.Powerpoint", "com.microsoft.PowerPoint"]),
        .init(id: "markdown", displayName: "Markdown", fileExtension: "md", resourceName: "markdown.md", sortOrder: 6, preferredBundleIDs: []),
        .init(id: "html", displayName: "HTML", fileExtension: "html", resourceName: "html.html", sortOrder: 7, preferredBundleIDs: []),
        .init(id: "xml", displayName: "XML", fileExtension: "xml", resourceName: "xml.xml", sortOrder: 8, preferredBundleIDs: []),
        .init(id: "css", displayName: "CSS", fileExtension: "css", resourceName: "css.css", sortOrder: 9, preferredBundleIDs: []),
        .init(id: "javascript", displayName: "JavaScript", fileExtension: "js", resourceName: "javascript.js", sortOrder: 10, preferredBundleIDs: []),
        .init(id: "python", displayName: "Python", fileExtension: "py", resourceName: "python.py", sortOrder: 11, preferredBundleIDs: []),
        .init(id: "shell", displayName: "Shell", fileExtension: "sh", resourceName: "shell.sh", sortOrder: 12, preferredBundleIDs: []),
    ]

    public static let templates: [ConfigurableNewFileTemplate] = entries.map { entry in
        ConfigurableNewFileTemplate(
            id: entry.id,
            displayName: entry.displayName,
            fileExtension: entry.fileExtension,
            enabled: true,
            sortOrder: entry.sortOrder,
            templateSource: .builtInResource(entry.resourceName),
            originalFileName: entry.resourceName,
            preferredBundleIDs: entry.preferredBundleIDs
        )
    }

    public static func resourceName(for id: String) -> String? {
        entries.first { $0.id == id }?.resourceName
    }
}

public struct NewFileTemplateSourceResolver {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func templateURL(for source: NewFileTemplateSource) -> URL? {
        switch source {
        case let .builtInResource(resourceName):
            return builtInTemplateURL(resourceName: resourceName)
        case let .managedUserFile(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return templateExists(at: url) ? url : nil
        }
    }

    public func builtInTemplateURL(resourceName: String) -> URL? {
        for directory in builtInTemplateDirectories() {
            let url = directory.appendingPathComponent(resourceName)
            if templateExists(at: url) { return url }
        }
        return nil
    }

    public func builtInManifestURL() -> URL? {
        for directory in builtInTemplateDirectories() {
            let url = directory.appendingPathComponent(BuiltInNewFileTemplateManifest.manifestFileName)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func builtInTemplateDirectories() -> [URL] {
        // 两条构建链路都将资源交给 ArcKitFinder，不再根据进程 cwd 猜测模板位置。
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: FinderTemplateResourceBundle.self)
        #endif
        return bundle.resourceURL.map {
            [$0.appendingPathComponent(BuiltInNewFileTemplateManifest.resourceDirectoryName)]
        } ?? []
    }

    private func templateExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) == false
        }
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return false
        }
        return size.intValue >= 0
    }
}

public struct NewFileTemplateLibrary {
    private let fileManager: FileManager
    private let baseDirectory: URL

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
    }

    public static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        ArcKitStoragePaths.current.templates
    }

    public func importTemplate(from sourceURL: URL, displayName: String? = nil, id: String? = nil, sortOrder: Int) throws -> ConfigurableNewFileTemplate {
        let ext = sourceURL.pathExtension.lowercased()
        guard !ext.isEmpty else {
            throw NewFileTemplateImportError.missingFileExtension
        }
        let normalizedDisplayName = (displayName ?? sourceURL.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty,
              normalizedDisplayName.count <= 40,
              !normalizedDisplayName.contains("\n"),
              !normalizedDisplayName.contains("\r")
        else {
            throw NewFileTemplateImportError.invalidDisplayName
        }
        let templateID = id ?? "custom-\(UUID().uuidString)"
        let safeName = sourceURL.lastPathComponent
        let destinationDirectory = baseDirectory.appendingPathComponent(templateID, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = uniqueURL(destinationDirectory.appendingPathComponent(safeName))
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return ConfigurableNewFileTemplate(
            id: templateID,
            displayName: normalizedDisplayName,
            fileExtension: ext,
            enabled: true,
            sortOrder: sortOrder,
            templateSource: .managedUserFile(destinationURL.path),
            originalFileName: sourceURL.lastPathComponent
        )
    }

    private func uniqueURL(_ url: URL) -> URL {
        if !fileManager.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        for index in 2...999 {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}

private final class FinderTemplateResourceBundle: NSObject {}
