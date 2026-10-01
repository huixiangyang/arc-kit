import ArcKitFinder
import ArcKitPlatform
import ArcKitMouse
import ArcKitWindow
import Foundation

public struct SettingsBackupTemplateEntry: Codable, Equatable, Sendable {
    public var relativePath: String
    public var isDirectory: Bool
    public var contents: Data?

    public init(relativePath: String, isDirectory: Bool, contents: Data? = nil) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.contents = contents
    }
}

public struct SettingsBackupManagedTemplate: Codable, Equatable, Sendable {
    public var templateID: String
    public var rootFileName: String
    public var isDirectory: Bool
    public var entries: [SettingsBackupTemplateEntry]

    public init(
        templateID: String,
        rootFileName: String,
        isDirectory: Bool,
        entries: [SettingsBackupTemplateEntry]
    ) {
        self.templateID = templateID
        self.rootFileName = rootFileName
        self.isDirectory = isDirectory
        self.entries = entries
    }
}

public struct SettingsBackupDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var productIdentifier: String
    public var applicationVersion: String
    public var createdAt: Date
    public var settingsSchemaVersion: Int
    public var settings: AppSettings
    public var managedTemplates: [SettingsBackupManagedTemplate]

    public init(
        formatVersion: Int = SettingsBackupDocument.formatVersion,
        productIdentifier: String = ArcKitConstants.appBundleIdentifier,
        applicationVersion: String,
        createdAt: Date,
        settingsSchemaVersion: Int = AppSettings.schemaVersion,
        settings: AppSettings,
        managedTemplates: [SettingsBackupManagedTemplate]
    ) {
        self.formatVersion = formatVersion
        self.productIdentifier = productIdentifier
        self.applicationVersion = applicationVersion
        self.createdAt = createdAt
        self.settingsSchemaVersion = settingsSchemaVersion
        self.settings = settings
        self.managedTemplates = managedTemplates
    }
}

public struct SettingsBackupMetadata: Equatable, Sendable {
    public var createdAt: Date
    public var applicationVersion: String
    public var managedTemplateCount: Int
    public var attachmentByteCount: Int

    public init(
        createdAt: Date,
        applicationVersion: String,
        managedTemplateCount: Int,
        attachmentByteCount: Int
    ) {
        self.createdAt = createdAt
        self.applicationVersion = applicationVersion
        self.managedTemplateCount = managedTemplateCount
        self.attachmentByteCount = attachmentByteCount
    }
}

public struct MaterializedSettingsBackup: Sendable {
    public let settings: AppSettings
    fileprivate let stagingDirectory: URL?
}

public enum SettingsBackupError: LocalizedError, Equatable, Sendable {
    case backupTooLarge(maximumBytes: Int)
    case incompatibleFormat(expected: Int, actual: Int?)
    case incompatibleProduct
    case incompatibleSettingsSchema(expected: Int, actual: Int?)
    case invalidDocument(String)
    case managedTemplateUnavailable(String)
    case unsupportedTemplateItem(String)
    case readFailed(String)
    case writeFailed(String)
    case recoveryTransactionFailed(primary: String, automaticBackupRollback: String)
    case automaticBackupUnavailable
    case operationInProgress
    case settingsChangedDuringTransfer

    public var errorDescription: String? {
        switch self {
        case let .backupTooLarge(maximumBytes):
            L10n.string(.DataManagement.backupSizeLimit(String(describing: L10n.fileSize(Int64(maximumBytes)))))
        case let .incompatibleFormat(expected, actual):
            L10n.string(.DataManagement.backupFormatMismatch(String(describing: expected), String(describing: actual.map(String.init) ?? L10n.string(.Common.unknown))))
        case .incompatibleProduct:
            L10n.string(.DataManagement.backupInvalidPackage)
        case let .incompatibleSettingsSchema(expected, actual):
            L10n.string(.DataManagement.backupSettingsVersionMismatch(String(describing: expected), String(describing: actual.map(String.init) ?? L10n.string(.Common.unknown))))
        case let .invalidDocument(detail):
            L10n.string(.DataManagement.backupBackupDamagedModified(String(describing: detail)))
        case let .managedTemplateUnavailable(path):
            L10n.string(.DataManagement.backupTemplateReadFailed(String(describing: path)))
        case let .unsupportedTemplateItem(path):
            L10n.string(.DataManagement.backupUnsupportedTemplateFile(String(describing: path)))
        case let .readFailed(detail):
            L10n.string(.DataManagement.backupReadFailed(String(describing: detail)))
        case let .writeFailed(detail):
            L10n.string(.DataManagement.backupWriteFailed(String(describing: detail)))
        case let .recoveryTransactionFailed(primary, automaticBackupRollback):
            L10n.string(.DataManagement.backupRollbackFailed(String(describing: primary), String(describing: automaticBackupRollback)))
        case .automaticBackupUnavailable:
            L10n.string(.DataManagement.backupRecentAutomaticBackupRestoreMissing)
        case .settingsChangedDuringTransfer:
            L10n.string(.DataManagement.backupConcurrentChange)
        case .operationInProgress:
            L10n.string(.DataManagement.backupAnotherSettingsBackupRestore)
        }
    }
}

/// 设置备份使用单文件 JSON，并把用户托管模板以 Base64 一并封装。
/// 这样恢复和迁移都不依赖旧机器上的绝对路径，也不会产生“设置导出了、模板却丢了”的假备份。
public final class SettingsBackupService: @unchecked Sendable {
    public static let maximumBackupByteCount = 100 * 1_024 * 1_024
    private static let maximumTemplateEntryCount = 10_000
    private static let maximumTemplatePathDepth = 64

    public let automaticBackupURL: URL

    private let fileManager: FileManager
    private let managedTemplateDirectory: URL
    private let maximumBackupByteCount: Int

    public init(
        fileManager: FileManager = .default,
        automaticBackupURL: URL? = nil,
        managedTemplateDirectory: URL? = nil,
        maximumBackupByteCount: Int = SettingsBackupService.maximumBackupByteCount
    ) {
        self.fileManager = fileManager
        self.managedTemplateDirectory = managedTemplateDirectory
            ?? NewFileTemplateLibrary.defaultBaseDirectory(fileManager: fileManager)
        self.automaticBackupURL = automaticBackupURL
            ?? Self.defaultAutomaticBackupURL(fileManager: fileManager)
        self.maximumBackupByteCount = maximumBackupByteCount
    }

    public static func defaultAutomaticBackupURL(fileManager: FileManager = .default) -> URL {
        ArcKitStoragePaths.current.backups.appendingPathComponent("LastSettingsBackup.json")
    }

    @discardableResult
    public func export(
        settings: AppSettings,
        applicationVersion: String,
        to url: URL,
        createdAt: Date = Date()
    ) throws -> SettingsBackupMetadata {
        let document = try makeDocument(
            settings: settings,
            applicationVersion: applicationVersion,
            createdAt: createdAt
        )
        return try persist(document, to: url)
    }

    @discardableResult
    public func saveAutomaticBackup(
        settings: AppSettings,
        applicationVersion: String,
        createdAt: Date = Date()
    ) throws -> SettingsBackupMetadata {
        try export(
            settings: settings,
            applicationVersion: applicationVersion,
            to: automaticBackupURL,
            createdAt: createdAt
        )
    }

    @discardableResult
    public func saveAutomaticDocument(_ document: SettingsBackupDocument) throws -> SettingsBackupMetadata {
        try validate(document)
        return try persist(document, to: automaticBackupURL)
    }

    /// 自动备份轮换与手动导出遵守同一套落盘门禁，不能让回滚写入绕过逐字节回读和完整解码。
    private func persist(_ document: SettingsBackupDocument, to url: URL) throws -> SettingsBackupMetadata {
        let data = try encode(document)
        do {
            try ArcKitAtomicFile.writeAtomically(data, to: url, fileManager: fileManager)
        } catch {
            throw SettingsBackupError.writeFailed(error.localizedDescription)
        }
        let persistedData: Data
        do {
            persistedData = try ArcKitBoundedFileReader.read(
                from: url,
                maximumBytes: maximumBackupByteCount
            )
        } catch {
            throw SettingsBackupError.writeFailed(L10n.string(.DataManagement.backupReadbackFailed(String(describing: error.localizedDescription))))
        }
        guard persistedData == data else {
            throw SettingsBackupError.writeFailed(L10n.string(.DataManagement.backupByteByteVerificationWritingFailed))
        }
        do {
            _ = try decode(persistedData)
        } catch {
            throw SettingsBackupError.writeFailed(L10n.string(.DataManagement.backupFullValidationWritingFailed(String(describing: error.localizedDescription))))
        }
        return metadata(for: document)
    }

    public func loadDocument(from url: URL) throws -> SettingsBackupDocument {
        let data: Data
        do {
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            if let size, size.intValue > maximumBackupByteCount {
                throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
            }
            data = try ArcKitBoundedFileReader.read(
                from: url,
                maximumBytes: maximumBackupByteCount
            )
        } catch let error as SettingsBackupError {
            throw error
        } catch is ArcKitBoundedFileReaderError {
            throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
        } catch {
            throw SettingsBackupError.readFailed(error.localizedDescription)
        }
        return try decode(data)
    }

    public func loadAutomaticBackup() throws -> SettingsBackupDocument {
        guard fileManager.fileExists(atPath: automaticBackupURL.path) else {
            throw SettingsBackupError.automaticBackupUnavailable
        }
        return try loadDocument(from: automaticBackupURL)
    }

    public func automaticBackupMetadata() -> SettingsBackupMetadata? {
        try? inspectAutomaticBackupMetadata()
    }

    /// 缺少备份与备份损坏是两种不同产品状态；设置页必须能把后者明确呈现给用户。
    public func inspectAutomaticBackupMetadata() throws -> SettingsBackupMetadata? {
        guard fileManager.fileExists(atPath: automaticBackupURL.path) else { return nil }
        return metadata(for: try loadAutomaticBackup())
    }

    public func materialize(_ document: SettingsBackupDocument) throws -> MaterializedSettingsBackup {
        try validate(document)
        guard !document.managedTemplates.isEmpty else {
            return MaterializedSettingsBackup(settings: document.settings, stagingDirectory: nil)
        }

        let stagingDirectory = managedTemplateDirectory
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            var restoredSettings = document.settings
            let payloads = document.managedTemplates.reduce(into: [String: SettingsBackupManagedTemplate]()) {
                $0[$1.templateID] = $1
            }

            for index in restoredSettings.finder.menuConfiguration.fileTemplates.indices {
                let template = restoredSettings.finder.menuConfiguration.fileTemplates[index]
                guard case .managedUserFile = template.templateSource else { continue }
                guard let payload = payloads[template.id] else {
                    throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupCustomTemplateFileContentsMissing(String(describing: template.displayName))))
                }
                let restoredURL = try restore(payload, under: stagingDirectory)
                restoredSettings.finder.menuConfiguration.fileTemplates[index].templateSource = .managedUserFile(restoredURL.path)
            }
            return MaterializedSettingsBackup(settings: restoredSettings, stagingDirectory: stagingDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    public func discard(_ materializedBackup: MaterializedSettingsBackup) {
        guard let directory = materializedBackup.stagingDirectory else { return }
        try? fileManager.removeItem(at: directory)
    }

    public func metadata(for document: SettingsBackupDocument) -> SettingsBackupMetadata {
        SettingsBackupMetadata(
            createdAt: document.createdAt,
            applicationVersion: document.applicationVersion,
            managedTemplateCount: document.managedTemplates.count,
            attachmentByteCount: document.managedTemplates.reduce(0) { total, template in
                total + template.entries.reduce(0) { $0 + ($1.contents?.count ?? 0) }
            }
        )
    }
}

private extension SettingsBackupService {
    func makeDocument(
        settings: AppSettings,
        applicationVersion: String,
        createdAt: Date
    ) throws -> SettingsBackupDocument {
        guard settings.schemaVersion == AppSettings.schemaVersion else {
            throw SettingsBackupError.incompatibleSettingsSchema(
                expected: AppSettings.schemaVersion,
                actual: settings.schemaVersion
            )
        }
        let version = applicationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupAppVersionRequired))
        }

        var totalBytes = 0
        var managedTemplates: [SettingsBackupManagedTemplate] = []
        for template in settings.finder.menuConfiguration.fileTemplates {
            guard case let .managedUserFile(path) = template.templateSource else { continue }
            let payload = try captureManagedTemplate(templateID: template.id, path: path, totalBytes: &totalBytes)
            managedTemplates.append(payload)
        }
        let document = SettingsBackupDocument(
            applicationVersion: version,
            createdAt: createdAt,
            settings: settings,
            managedTemplates: managedTemplates.sorted { $0.templateID < $1.templateID }
        )
        try validate(document)
        return document
    }

    func encode(_ document: SettingsBackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(document)
            guard data.count <= maximumBackupByteCount else {
                throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
            }
            return data
        } catch let error as SettingsBackupError {
            throw error
        } catch {
            throw SettingsBackupError.invalidDocument(error.localizedDescription)
        }
    }

    func decode(_ data: Data) throws -> SettingsBackupDocument {
        guard data.count <= maximumBackupByteCount else {
            throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
        }
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupInvalidJson))
        }
        guard let raw = rawObject as? [String: Any] else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupRootObject))
        }

        let actualFormat = raw["formatVersion"] as? Int
        guard actualFormat == SettingsBackupDocument.formatVersion else {
            throw SettingsBackupError.incompatibleFormat(
                expected: SettingsBackupDocument.formatVersion,
                actual: actualFormat
            )
        }
        guard raw["productIdentifier"] as? String == ArcKitConstants.appBundleIdentifier else {
            throw SettingsBackupError.incompatibleProduct
        }
        let actualSettingsSchema = raw["settingsSchemaVersion"] as? Int
        guard actualSettingsSchema == AppSettings.schemaVersion else {
            throw SettingsBackupError.incompatibleSettingsSchema(
                expected: AppSettings.schemaVersion,
                actual: actualSettingsSchema
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: SettingsBackupDocument
        do {
            document = try decoder.decode(SettingsBackupDocument.self, from: data)
        } catch {
            throw SettingsBackupError.invalidDocument(error.localizedDescription)
        }
        try validate(document)

        // Codable 默认忽略未知字段，且部分旧模型会把坏数据回退成默认值；
        // 对导入文件必须做规范化 JSON 精确回读，任何字段丢失、篡改或兼容回退都直接拒绝。
        let canonicalData = try encode(document)
        let canonicalObject = try JSONSerialization.jsonObject(with: canonicalData)
        guard (rawObject as AnyObject).isEqual(canonicalObject) else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupSchemaMismatch))
        }
        return document
    }

    func validate(_ document: SettingsBackupDocument) throws {
        guard document.formatVersion == SettingsBackupDocument.formatVersion else {
            throw SettingsBackupError.incompatibleFormat(
                expected: SettingsBackupDocument.formatVersion,
                actual: document.formatVersion
            )
        }
        guard document.productIdentifier == ArcKitConstants.appBundleIdentifier else {
            throw SettingsBackupError.incompatibleProduct
        }
        guard document.settingsSchemaVersion == AppSettings.schemaVersion,
              document.settings.schemaVersion == AppSettings.schemaVersion
        else {
            throw SettingsBackupError.incompatibleSettingsSchema(
                expected: AppSettings.schemaVersion,
                actual: document.settingsSchemaVersion
            )
        }

        let managedIDs = document.settings.finder.menuConfiguration.fileTemplates.compactMap { template -> String? in
            guard case .managedUserFile = template.templateSource else { return nil }
            return template.id
        }
        let canonicalManagedIDs = managedIDs.map(canonicalFileSystemKey)
        guard Set(canonicalManagedIDs).count == canonicalManagedIDs.count else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupDuplicateCustomTemplateIds))
        }
        let payloadIDs = document.managedTemplates.map(\.templateID)
        let canonicalPayloadIDs = payloadIDs.map(canonicalFileSystemKey)
        guard Set(canonicalPayloadIDs).count == canonicalPayloadIDs.count,
              Set(canonicalPayloadIDs) == Set(canonicalManagedIDs),
              Set(payloadIDs) == Set(managedIDs)
        else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateMismatch))
        }

        var totalBytes = 0
        var totalEntries = 0
        for payload in document.managedTemplates {
            try validateSafeComponent(payload.templateID, field: L10n.string(.DataManagement.backupTemplateId))
            try validateSafeComponent(payload.rootFileName, field: L10n.string(.DataManagement.backupTemplateFilename))
            guard !payload.entries.isEmpty else {
                throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateFileContentsMissing(String(describing: payload.templateID))))
            }
            totalEntries += payload.entries.count
            guard totalEntries <= Self.maximumTemplateEntryCount else {
                throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupCustomTemplateFileEntriesExceed(String(describing: Self.maximumTemplateEntryCount))))
            }
            let entryPaths = payload.entries.map(\.relativePath)
            let canonicalEntryPaths = entryPaths.map(canonicalFileSystemKey)
            guard Set(canonicalEntryPaths).count == canonicalEntryPaths.count else {
                throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateContainsDuplicateFilePaths(String(describing: payload.templateID))))
            }
            for entry in payload.entries {
                try validateRelativePath(entry.relativePath, allowsEmpty: !payload.isDirectory)
                if entry.isDirectory {
                    guard entry.contents == nil, !entry.relativePath.isEmpty else {
                        throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupInvalidTemplateDirectoryEntryFormat))
                    }
                } else {
                    guard entry.contents != nil else {
                        throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateFileEntryContentsMissing))
                    }
                    totalBytes += entry.contents?.count ?? 0
                    guard totalBytes <= maximumBackupByteCount else {
                        throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
                    }
                }
            }
            if payload.isDirectory {
                guard payload.entries.allSatisfy({ !$0.relativePath.isEmpty }) else {
                    throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupEmptyTemplatePath))
                }
            } else {
                guard payload.entries.count == 1,
                      payload.entries[0].relativePath.isEmpty,
                      !payload.entries[0].isDirectory
                else {
                    throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupFileTemplatesContainExactlyOneRoot))
                }
            }
        }
    }

    func captureManagedTemplate(
        templateID: String,
        path: String,
        totalBytes: inout Int
    ) throws -> SettingsBackupManagedTemplate {
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let values: URLResourceValues
        do {
            values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw SettingsBackupError.managedTemplateUnavailable(rootURL.path)
        }
        guard values.isSymbolicLink != true else {
            throw SettingsBackupError.unsupportedTemplateItem(rootURL.path)
        }
        let rootName = rootURL.lastPathComponent
        try validateSafeComponent(rootName, field: L10n.string(.DataManagement.backupTemplateFilename))

        if values.isDirectory == true {
            var entries: [SettingsBackupTemplateEntry] = []
            try captureDirectory(rootURL, relativePrefix: "", entries: &entries, totalBytes: &totalBytes)
            guard !entries.isEmpty else {
                throw SettingsBackupError.managedTemplateUnavailable(rootURL.path)
            }
            return SettingsBackupManagedTemplate(
                templateID: templateID,
                rootFileName: rootName,
                isDirectory: true,
                entries: entries.sorted { $0.relativePath < $1.relativePath }
            )
        }
        guard values.isRegularFile == true else {
            throw SettingsBackupError.unsupportedTemplateItem(rootURL.path)
        }
        let data = try readTemplateFile(rootURL, totalBytes: &totalBytes)
        return SettingsBackupManagedTemplate(
            templateID: templateID,
            rootFileName: rootName,
            isDirectory: false,
            entries: [SettingsBackupTemplateEntry(relativePath: "", isDirectory: false, contents: data)]
        )
    }

    func captureDirectory(
        _ directory: URL,
        relativePrefix: String,
        entries: inout [SettingsBackupTemplateEntry],
        totalBytes: inout Int
    ) throws {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw SettingsBackupError.managedTemplateUnavailable(directory.path)
        }
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SettingsBackupError.unsupportedTemplateItem(child.path)
            }
            // 使用递归前缀构造相对路径，不从绝对路径做字符串裁剪；
            // APFS/HFS 的 Unicode 规范化差异否则会把根目录名错误嵌套一层。
            let relativePath = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            try validateRelativePath(relativePath, allowsEmpty: false)
            guard entries.count < Self.maximumTemplateEntryCount else {
                throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupCustomTemplateFileEntriesExceed(String(describing: Self.maximumTemplateEntryCount))))
            }
            if values.isDirectory == true {
                entries.append(SettingsBackupTemplateEntry(relativePath: relativePath, isDirectory: true))
                try captureDirectory(child, relativePrefix: relativePath, entries: &entries, totalBytes: &totalBytes)
            } else if values.isRegularFile == true {
                entries.append(SettingsBackupTemplateEntry(
                    relativePath: relativePath,
                    isDirectory: false,
                    contents: try readTemplateFile(child, totalBytes: &totalBytes)
                ))
            } else {
                throw SettingsBackupError.unsupportedTemplateItem(child.path)
            }
        }
    }

    func readTemplateFile(_ url: URL, totalBytes: inout Int) throws -> Data {
        do {
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            if let size, totalBytes + size.intValue > maximumBackupByteCount {
                throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
            }
            let data = try ArcKitBoundedFileReader.read(
                from: url,
                maximumBytes: maximumBackupByteCount
            )
            totalBytes += data.count
            guard totalBytes <= maximumBackupByteCount else {
                throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
            }
            return data
        } catch let error as SettingsBackupError {
            throw error
        } catch is ArcKitBoundedFileReaderError {
            throw SettingsBackupError.backupTooLarge(maximumBytes: maximumBackupByteCount)
        } catch {
            throw SettingsBackupError.managedTemplateUnavailable(url.path)
        }
    }

    func restore(_ payload: SettingsBackupManagedTemplate, under stagingDirectory: URL) throws -> URL {
        let templateDirectory = stagingDirectory.appendingPathComponent(payload.templateID, isDirectory: true)
        try fileManager.createDirectory(at: templateDirectory, withIntermediateDirectories: true)
        let rootURL = templateDirectory.appendingPathComponent(payload.rootFileName, isDirectory: payload.isDirectory)

        if payload.isDirectory {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            for entry in payload.entries where entry.isDirectory {
                let destination = try safeDestination(for: entry.relativePath, under: rootURL)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            for entry in payload.entries where !entry.isDirectory {
                guard let contents = entry.contents else {
                    throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateFileEntryContentsMissing))
                }
                let destination = try safeDestination(for: entry.relativePath, under: rootURL)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try ArcKitAtomicFile.writeAtomically(contents, to: destination, fileManager: fileManager)
            }
        } else {
            guard let contents = payload.entries.first?.contents else {
                throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateRootFileContentsMissing))
            }
            try ArcKitAtomicFile.writeAtomically(contents, to: rootURL, fileManager: fileManager)
        }
        return rootURL
    }

    func safeDestination(for relativePath: String, under root: URL) throws -> URL {
        try validateRelativePath(relativePath, allowsEmpty: false)
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        guard destination.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupTemplateRelativePathOutBounds))
        }
        return destination
    }

    func validateRelativePath(_ path: String, allowsEmpty: Bool) throws {
        if path.isEmpty, allowsEmpty { return }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupInvalidTemplateRelativePath))
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= Self.maximumTemplatePathDepth else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupInvalidTemplateRelativePath))
        }
        for component in components {
            try validateSafeComponent(component, field: L10n.string(.DataManagement.backupTemplateRelativePath))
        }
    }

    func validateSafeComponent(_ component: String, field: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\\"),
              !component.contains("\0"),
              component.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw SettingsBackupError.invalidDocument(L10n.string(.DataManagement.backupInvalid(String(describing: field))))
        }
    }

    func canonicalFileSystemKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
