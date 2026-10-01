import ArcKitPlatform
import Foundation

public enum NewFileTemplateSource: Codable, Equatable, Sendable {
    case builtInResource(String)
    case managedUserFile(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case builtInResource
        case managedUserFile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: L10n.string(.Finder.templateSourceRequired)
            )
        }
        switch kind {
        case .builtInResource:
            guard !value.contains("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: L10n.string(.Finder.templateInvalidResourceName)
                )
            }
            self = .builtInResource(value)
        case .managedUserFile:
            guard value.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: L10n.string(.Finder.templateCustomTemplateFilePathsAbsolute)
                )
            }
            self = .managedUserFile(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .builtInResource(resourceName):
            try container.encode(Kind.builtInResource, forKey: .kind)
            try container.encode(resourceName, forKey: .value)
        case let .managedUserFile(path):
            try container.encode(Kind.managedUserFile, forKey: .kind)
            try container.encode(path, forKey: .value)
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case let .builtInResource(resourceName):
            "builtInResource:\(resourceName)"
        case let .managedUserFile(path):
            "managedUserFile:\(path)"
        }
    }
}

/// 可配置的新建文件模板，支持真实模板复制、排序和创建后打开。
public struct ConfigurableNewFileTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var fileExtension: String
    public var enabled: Bool
    public var sortOrder: Int
    public var isPinnedToRootMenu: Bool
    public var openAfterCreate: Bool
    public var templateSource: NewFileTemplateSource?
    public var originalFileName: String?
    public var preferredBundleIDs: [String]

    public init(
        id: String,
        displayName: String,
        fileExtension: String,
        enabled: Bool = true,
        sortOrder: Int,
        isPinnedToRootMenu: Bool = false,
        openAfterCreate: Bool = false,
        templateSource: NewFileTemplateSource? = nil,
        originalFileName: String? = nil,
        preferredBundleIDs: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtension = fileExtension
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.isPinnedToRootMenu = isPinnedToRootMenu
        self.openAfterCreate = openAfterCreate
        self.templateSource = templateSource
        self.originalFileName = originalFileName
        self.preferredBundleIDs = preferredBundleIDs
    }

    public var normalizedExtension: String {
        let trimmed = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
    }

    public var localizedDisplayName: String {
        // 仅内置且未改名的模板使用译文；用户模板与自定义名称始终保留原文。
        guard case .builtInResource? = templateSource else { return displayName }
        switch (id, displayName) {
        case ("wps", "WPS 文档"), ("wps", "WPS Document"): return L10n.string(.Finder.templateWpsDocument) // i18n-ignore: 内置原名
        case ("et", "WPS 表格"), ("et", "WPS Spreadsheet"): return L10n.string(.Finder.templateWpsSpreadsheet) // i18n-ignore: 内置原名
        case ("dps", "WPS 演示"), ("dps", "WPS Presentation"): return L10n.string(.Finder.templateWpsPresentation) // i18n-ignore: 内置原名
        default: return displayName
        }
    }

    public var defaultFileName: String {
        let suffix = normalizedExtension
        return suffix.isEmpty ? L10n.string(.Finder.templateNew(String(describing: localizedDisplayName))) : L10n.string(.Finder.templateNewDocumentName(String(describing: localizedDisplayName), String(describing: suffix)))
    }

    /// 软件图标尚未加载时使用的 Lucide 占位，供 Finder 扩展和预览 UI 共用。
    public var icon: ArcIconName {
        switch normalizedExtension.lowercased() {
        case "txt", "rtf", "md", "markdown": .fileText
        case "json": .braces
        case "doc", "docx", "wps", "pages": .fileText
        case "xls", "xlsx", "et", "numbers": .table2
        case "ppt", "pptx", "dps", "key", "keynote": .presentation
        case "html", "xml": .codeXml
        case "css": .paintbrush
        case "js", "javascript": .squareCode
        case "py", "python", "sh", "zsh", "bash": .terminal
        default: .file
        }
    }

    /// 新建模板优先展示的应用图标 Bundle ID，由当前模板配置显式决定。
    public var preferredApplicationBundleIdentifiers: [String] {
        if !preferredBundleIDs.isEmpty { return preferredBundleIDs }
        return switch normalizedExtension.lowercased() {
        case "txt", "rtf":
            ["com.apple.TextEdit"]
        case "doc", "docx":
            ["com.microsoft.Word", "com.kingsoft.wpsoffice.mac"]
        case "xls", "xlsx":
            ["com.microsoft.Excel", "com.kingsoft.wpsoffice.mac"]
        case "ppt", "pptx":
            ["com.microsoft.Powerpoint", "com.kingsoft.wpsoffice.mac"]
        case "pages":
            ["com.apple.iWork.Pages"]
        case "numbers":
            ["com.apple.iWork.Numbers"]
        case "key", "keynote":
            ["com.apple.iWork.Keynote"]
        case "wps", "et", "dps":
            ["com.kingsoft.wpsoffice.mac"]
        default:
            []
        }
    }

    /// 新建模板展示图标使用的应用 Bundle ID。
    ///
    /// 品牌化模板必须保持身份边界：Microsoft Office 只使用 Microsoft 图标，
    /// WPS 只使用 WPS 图标，避免被系统默认打开应用劫持。
    public var iconApplicationBundleIdentifiers: [String] {
        switch normalizedExtension.lowercased() {
        case "docx":
            ["com.microsoft.Word"]
        case "xlsx":
            ["com.microsoft.Excel"]
        case "pptx":
            ["com.microsoft.Powerpoint", "com.microsoft.PowerPoint"]
        case "wps", "et", "dps":
            ["com.kingsoft.wpsoffice.mac"]
        case "pages":
            ["com.apple.iWork.Pages"]
        case "numbers":
            ["com.apple.iWork.Numbers"]
        case "key", "keynote":
            ["com.apple.iWork.Keynote"]
        default:
            preferredApplicationBundleIdentifiers
        }
    }

    /// 是否允许使用系统默认打开 App 的图标兜底。
    ///
    /// 对 Office/iWork/WPS 这类带明确品牌归属的模板，默认打开方式可能被用户改成其它 App；
    /// 继续使用默认 App 会让 Word 显示成 WPS、Pages 显示成解压工具等，因此这些类型只在
    /// 对应应用真实安装时取应用图标，否则退回文件类型图标。
    public var allowsDefaultApplicationIconFallback: Bool {
        switch normalizedExtension.lowercased() {
        case "docx", "xlsx", "pptx", "pages", "numbers", "key", "keynote", "wps", "et", "dps":
            false
        default:
            true
        }
    }

    /// 是否能创建可被对应应用直接打开的有效文件。
    public var isFinderNewFileSupported: Bool {
        guard let source = resolvedTemplateSource else { return false }
        return NewFileTemplateSourceResolver().templateURL(for: source) != nil
    }

    public var resolvedTemplateSource: NewFileTemplateSource? {
        if let templateSource { return templateSource }
        return BuiltInNewFileTemplateManifest.resourceName(for: id).map(NewFileTemplateSource.builtInResource)
    }

    /// 旧版二进制 Office 格式没有内置模板资源时不显示，避免生成打不开的假文件。
    public var isUnsupportedComplexDocument: Bool {
        switch normalizedExtension.lowercased() {
        case "doc", "xls", "ppt":
            true
        default:
            false
        }
    }

    public var unsupportedReason: String? {
        if isUnsupportedComplexDocument {
            return L10n.string(.Finder.templateHiddenRealTemplateFileArcKitMissing)
        }
        if resolvedTemplateSource == nil {
            return L10n.string(.Finder.templateHiddenTemplateFileMissing)
        }
        if !isFinderNewFileSupported {
            return L10n.string(.Finder.templateHiddenTemplateSourceMissingUnreadable)
        }
        return nil
    }

    public static let defaults: [ConfigurableNewFileTemplate] = BuiltInNewFileTemplateManifest.templates
}

extension ConfigurableNewFileTemplate {
    enum CodingKeys: String, CodingKey {
        case id, displayName, fileExtension, enabled, sortOrder, isPinnedToRootMenu, openAfterCreate,
            templateSource, originalFileName, preferredBundleIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        isPinnedToRootMenu = try container.decode(Bool.self, forKey: .isPinnedToRootMenu)
        openAfterCreate = try container.decode(Bool.self, forKey: .openAfterCreate)
        templateSource = try container.decodeIfPresent(NewFileTemplateSource.self, forKey: .templateSource)
        originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName)
        preferredBundleIDs = try container.decode([String].self, forKey: .preferredBundleIDs)

        try Self.validateDecodedString(id, forKey: .id, fieldName: L10n.string(.Finder.actionNewFileTemplateId), container: container)
        try Self.validateDecodedString(displayName, forKey: .displayName, fieldName: L10n.string(.Finder.templateNewFileTemplateName), container: container)
        try Self.validateDecodedString(fileExtension, forKey: .fileExtension, fieldName: L10n.string(.Finder.templateNewFileTemplateExtension), container: container)
        guard !normalizedExtension.contains("/"), !normalizedExtension.contains("\\") else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileExtension,
                in: container,
                debugDescription: L10n.string(.Finder.templateInvalidExtension)
            )
        }
        if let originalFileName {
            try Self.validateDecodedString(originalFileName, forKey: .originalFileName, fieldName: L10n.string(.Finder.templateNewFileTemplateOriginalFilename), container: container)
        }
        var bundleIDs: Set<String> = []
        for bundleID in preferredBundleIDs {
            try Self.validateDecodedString(bundleID, forKey: .preferredBundleIDs, fieldName: L10n.string(.Finder.templateNewFileTemplateAppBundleId), container: container)
            guard bundleIDs.insert(bundleID).inserted else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preferredBundleIDs,
                    in: container,
                    debugDescription: L10n.string(.Finder.templateNewFileTemplateAppBundleIds)
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(isPinnedToRootMenu, forKey: .isPinnedToRootMenu)
        try container.encode(openAfterCreate, forKey: .openAfterCreate)
        try container.encodeIfPresent(templateSource, forKey: .templateSource)
        try container.encodeIfPresent(originalFileName, forKey: .originalFileName)
        try container.encode(preferredBundleIDs, forKey: .preferredBundleIDs)
    }

    private static func validateDecodedString(
        _ value: String,
        forKey key: CodingKeys,
        fieldName: String,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: L10n.string(.Finder.actionInvalidName(String(describing: fieldName)))
            )
        }
    }
}
