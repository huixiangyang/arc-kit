import ArcKitPlatform
import Foundation

public enum FinderCommandKind: String, Codable, Sendable, CaseIterable {
    /// 仅用于描述 Finder 扩展内展示的信息入口，永远不能进入 Agent 路由。
    case extensionLocalInfo
    case createNewFile
    case copyPaths
    case copyFileNames
    case copyFileInfo
    case copyHash
    case copyPickedColor
    case openTerminal
    case openWithApp
    case copyToDirectory
    case moveToDirectory
    case openPath
    case setFolderIcon
    case restoreFolderIcon
    case extractIcon
    case hideFiles
    case hideAllExceptFiles
    case lockFiles
    case deleteFiles
    case archiveFiles
    case moveIntoFolder
    case batchRename
    case convertImage
    case flattenFolder
    case runScript
}

public extension FinderCommandKind {
    /// 命令只有一个所属功能；UI 关闭功能后，Host 和 Worker 都拒绝已经打开的旧菜单。
    var menuModule: FinderMenuModuleID {
        switch self {
        case .createNewFile: .newFile
        case .copyPaths: .copyPath
        case .copyFileNames: .copyFileName
        case .copyFileInfo: .fileInfo
        case .copyHash: .copyHash
        case .copyPickedColor: .colorPicker
        case .openTerminal: .terminal
        case .openWithApp: .favoriteApps
        case .openPath: .favoriteDirectories
        case .setFolderIcon, .restoreFolderIcon: .folderIcon
        case .extractIcon: .extractIcon
        case .convertImage: .convertTo
        case .copyToDirectory, .moveToDirectory, .archiveFiles, .moveIntoFolder, .batchRename, .flattenFolder: .fileOrganization
        case .hideFiles, .hideAllExceptFiles, .lockFiles, .deleteFiles, .runScript, .extensionLocalInfo: .advancedTools
        }
    }
}

public enum FinderTargetResolutionPolicy: String, Codable, Sendable {
    case extensionTargetOnly
    /// 只从请求携带的上下文推导目录，不查询当前 Finder 窗口。
    case capturedContext
}

public enum FinderTerminalOpenMode: String, Codable, Sendable {
    case open
    case tab
    case window
}

public enum FinderClipboardResultKind: String, Codable, Sendable {
    case paths
    case fileNames
    case fileInfo
    case hash
    case color
}

public struct FinderPathPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var targetPath: String?
    public var targetResolutionPolicy: FinderTargetResolutionPolicy

    public init(
        sourcePaths: [String] = [],
        targetPath: String? = nil,
        targetResolutionPolicy: FinderTargetResolutionPolicy = .extensionTargetOnly
    ) {
        self.sourcePaths = sourcePaths
        self.targetPath = targetPath
        self.targetResolutionPolicy = targetResolutionPolicy
    }
}

public struct FinderNewFilePayload: Codable, Equatable, Sendable {
    public var templateID: String
    public var targetPath: String?
    public var targetResolutionPolicy: FinderTargetResolutionPolicy

    public init(
        templateID: String,
        targetPath: String? = nil,
        targetResolutionPolicy: FinderTargetResolutionPolicy = .extensionTargetOnly
    ) {
        self.templateID = templateID
        self.targetPath = targetPath
        self.targetResolutionPolicy = targetResolutionPolicy
    }
}

public struct FinderHashPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var algorithm: FileHashAlgorithm

    public init(sourcePaths: [String], algorithm: FileHashAlgorithm) {
        self.sourcePaths = sourcePaths
        self.algorithm = algorithm
    }
}

public struct FinderColorPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var includeHash: Bool

    public init(sourcePaths: [String], includeHash: Bool = true) {
        self.sourcePaths = sourcePaths
        self.includeHash = includeHash
    }
}

public struct FinderTerminalPayload: Codable, Equatable, Sendable {
    public var targetPath: String?
    public var targetResolutionPolicy: FinderTargetResolutionPolicy
    public var terminalApp: TerminalApp
    public var openMode: FinderTerminalOpenMode

    public init(
        targetPath: String? = nil,
        targetResolutionPolicy: FinderTargetResolutionPolicy = .extensionTargetOnly,
        terminalApp: TerminalApp,
        openMode: FinderTerminalOpenMode = .open
    ) {
        self.targetPath = targetPath
        self.targetResolutionPolicy = targetResolutionPolicy
        self.terminalApp = terminalApp
        self.openMode = openMode
    }
}

public struct FinderOpenWithAppPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var targetPath: String?
    public var targetResolutionPolicy: FinderTargetResolutionPolicy
    public var favoriteApplication: FavoriteApplication

    public init(
        sourcePaths: [String] = [],
        targetPath: String? = nil,
        targetResolutionPolicy: FinderTargetResolutionPolicy = .extensionTargetOnly,
        favoriteApplication: FavoriteApplication
    ) {
        self.sourcePaths = sourcePaths
        self.targetPath = targetPath
        self.targetResolutionPolicy = targetResolutionPolicy
        self.favoriteApplication = favoriteApplication
    }
}

public struct FinderSelectionPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]

    public init(sourcePaths: [String]) {
        self.sourcePaths = sourcePaths
    }
}

public struct FinderConfirmedSelectionPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var userConfirmed: Bool

    public init(sourcePaths: [String], userConfirmed: Bool) {
        self.sourcePaths = sourcePaths
        self.userConfirmed = userConfirmed
    }
}

public struct FinderToggleSelectionPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var enabled: Bool

    public init(sourcePaths: [String], enabled: Bool) {
        self.sourcePaths = sourcePaths
        self.enabled = enabled
    }
}

public struct FinderDirectoryTransferPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    /// `nil` 表示必须由常驻 Agent 展示目录选择器；Finder 扩展进程不得承载模态窗口。
    public var targetPath: String?

    public init(sourcePaths: [String], targetPath: String? = nil) {
        self.sourcePaths = sourcePaths
        self.targetPath = targetPath
    }
}

public struct FinderFolderIconPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var imagePath: String?

    public init(sourcePaths: [String], imagePath: String? = nil) {
        self.sourcePaths = sourcePaths
        self.imagePath = imagePath
    }
}

public struct FinderExtractIconPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var outputDirectoryPath: String?

    public init(sourcePaths: [String], outputDirectoryPath: String? = nil) {
        self.sourcePaths = sourcePaths
        self.outputDirectoryPath = outputDirectoryPath
    }
}

public struct FinderMoveIntoFolderPayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var folderName: String

    public init(sourcePaths: [String], folderName: String) {
        self.sourcePaths = sourcePaths
        self.folderName = folderName
    }
}

public struct FinderBatchRenamePayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    /// Finder 真实右键传 nil，由常驻 Agent 展示原生预览并收集规则；自动测试可直接注入规则。
    public var rule: FinderBatchRenameRule?

    public init(sourcePaths: [String], rule: FinderBatchRenameRule? = nil) {
        self.sourcePaths = sourcePaths
        self.rule = rule
    }
}

public struct FinderConvertImagePayload: Codable, Equatable, Sendable {
    public var sourcePaths: [String]
    public var format: String

    public init(sourcePaths: [String], format: String) {
        self.sourcePaths = sourcePaths
        self.format = format
    }
}

public struct FinderRunScriptPayload: Codable, Equatable, Sendable {
    public var scriptPath: String

    public init(scriptPath: String) {
        self.scriptPath = scriptPath
    }
}

public enum FinderCommandPayload: Codable, Equatable, Sendable {
    case createNewFile(FinderNewFilePayload)
    case copyPaths(FinderPathPayload)
    case copyFileNames(FinderPathPayload)
    case copyFileInfo(FinderPathPayload)
    case copyHash(FinderHashPayload)
    case copyPickedColor(FinderColorPayload)
    case openTerminal(FinderTerminalPayload)
    case openWithApp(FinderOpenWithAppPayload)
    case copyToDirectory(FinderDirectoryTransferPayload)
    case moveToDirectory(FinderDirectoryTransferPayload)
    case openPath(FinderPathPayload)
    case setFolderIcon(FinderFolderIconPayload)
    case restoreFolderIcon(FinderSelectionPayload)
    case extractIcon(FinderExtractIconPayload)
    case hideFiles(FinderToggleSelectionPayload)
    case hideAllExceptFiles(FinderSelectionPayload)
    case lockFiles(FinderToggleSelectionPayload)
    case deleteFiles(FinderConfirmedSelectionPayload)
    case archiveFiles(FinderSelectionPayload)
    case moveIntoFolder(FinderMoveIntoFolderPayload)
    case batchRename(FinderBatchRenamePayload)
    case convertImage(FinderConvertImagePayload)
    case flattenFolder(FinderSelectionPayload)
    case runScript(FinderRunScriptPayload)

    public var kind: FinderCommandKind {
        switch self {
        case .createNewFile: .createNewFile
        case .copyPaths: .copyPaths
        case .copyFileNames: .copyFileNames
        case .copyFileInfo: .copyFileInfo
        case .copyHash: .copyHash
        case .copyPickedColor: .copyPickedColor
        case .openTerminal: .openTerminal
        case .openWithApp: .openWithApp
        case .copyToDirectory: .copyToDirectory
        case .moveToDirectory: .moveToDirectory
        case .openPath: .openPath
        case .setFolderIcon: .setFolderIcon
        case .restoreFolderIcon: .restoreFolderIcon
        case .extractIcon: .extractIcon
        case .hideFiles: .hideFiles
        case .hideAllExceptFiles: .hideAllExceptFiles
        case .lockFiles: .lockFiles
        case .deleteFiles: .deleteFiles
        case .archiveFiles: .archiveFiles
        case .moveIntoFolder: .moveIntoFolder
        case .batchRename: .batchRename
        case .convertImage: .convertImage
        case .flattenFolder: .flattenFolder
        case .runScript: .runScript
        }
    }

    public var sourcePaths: [String] {
        switch self {
        case let .copyPaths(payload), let .copyFileNames(payload), let .copyFileInfo(payload), let .openPath(payload):
            payload.sourcePaths
        case let .copyHash(payload):
            payload.sourcePaths
        case let .copyPickedColor(payload):
            payload.sourcePaths
        case let .openWithApp(payload):
            payload.sourcePaths
        case let .copyToDirectory(payload), let .moveToDirectory(payload):
            payload.sourcePaths
        case let .setFolderIcon(payload):
            payload.sourcePaths
        case let .restoreFolderIcon(payload), let .hideAllExceptFiles(payload),
             let .archiveFiles(payload), let .flattenFolder(payload):
            payload.sourcePaths
        case let .deleteFiles(payload):
            payload.sourcePaths
        case let .extractIcon(payload):
            payload.sourcePaths
        case let .hideFiles(payload), let .lockFiles(payload):
            payload.sourcePaths
        case let .moveIntoFolder(payload):
            payload.sourcePaths
        case let .batchRename(payload):
            payload.sourcePaths
        case let .convertImage(payload):
            payload.sourcePaths
        case .createNewFile, .openTerminal, .runScript:
            []
        }
    }

    public var targetPath: String? {
        switch self {
        case let .createNewFile(payload):
            payload.targetPath
        case let .copyPaths(payload), let .copyFileNames(payload), let .copyFileInfo(payload), let .openPath(payload):
            payload.targetPath
        case let .openTerminal(payload):
            payload.targetPath
        case let .openWithApp(payload):
            payload.targetPath
        case let .copyToDirectory(payload), let .moveToDirectory(payload):
            payload.targetPath
        case let .extractIcon(payload):
            payload.outputDirectoryPath
        case .copyHash, .copyPickedColor, .setFolderIcon, .restoreFolderIcon, .hideFiles, .hideAllExceptFiles,
             .lockFiles, .deleteFiles, .archiveFiles, .moveIntoFolder, .batchRename, .convertImage, .flattenFolder, .runScript:
            nil
        }
    }

    public var targetResolutionPolicy: FinderTargetResolutionPolicy {
        switch self {
        case let .createNewFile(payload):
            payload.targetResolutionPolicy
        case let .copyPaths(payload), let .copyFileNames(payload), let .copyFileInfo(payload), let .openPath(payload):
            payload.targetResolutionPolicy
        case let .openTerminal(payload):
            payload.targetResolutionPolicy
        case let .openWithApp(payload):
            payload.targetResolutionPolicy
        default:
            .extensionTargetOnly
        }
    }
}

public struct FinderActionContext: Codable, Equatable, Sendable {
    public var selectedPaths: [String]
    public var targetedPath: String?
    public var menuKind: String?
    public var requestedAt: Date
    public var extensionProcessID: Int32
    public var extensionProcessName: String
    public var extensionBundlePath: String
    public var needsHostTargetResolution: Bool

    public init(
        selectedPaths: [String] = [],
        targetedPath: String? = nil,
        menuKind: String? = nil,
        requestedAt: Date = Date(),
        extensionProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        extensionProcessName: String = ProcessInfo.processInfo.processName,
        extensionBundlePath: String = Bundle.main.bundleURL.path,
        needsHostTargetResolution: Bool = false
    ) {
        self.selectedPaths = selectedPaths
        self.targetedPath = targetedPath
        self.menuKind = menuKind
        self.requestedAt = requestedAt
        self.extensionProcessID = extensionProcessID
        self.extensionProcessName = extensionProcessName
        self.extensionBundlePath = extensionBundlePath
        self.needsHostTargetResolution = needsHostTargetResolution
    }

    public var diagnosticDescription: String {
        "menuKind=\(menuKind ?? "-") selectedCount=\(selectedPaths.count) targetedPath=\(targetedPath ?? "-") needsHostTargetResolution=\(needsHostTargetResolution) extensionPID=\(extensionProcessID)"
    }
}

public struct FinderCommandRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var context: FinderActionContext
    public var payload: FinderCommandPayload
    public var createdAt: Date

    /// 命令类型只能由强类型 payload 派生，避免两个可写字段在运行期产生矛盾。
    public var kind: FinderCommandKind { payload.kind }

    public init(
        id: UUID = UUID(),
        context: FinderActionContext = FinderActionContext(),
        payload: FinderCommandPayload,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.context = context
        self.payload = payload
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, context, payload, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let encodedKind = try container.decode(FinderCommandKind.self, forKey: .kind)
        context = try container.decode(FinderActionContext.self, forKey: .context)
        payload = try container.decode(FinderCommandPayload.self, forKey: .payload)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        guard encodedKind == payload.kind else {
            throw DecodingError.dataCorruptedError(
                forKey: .payload,
                in: container,
                debugDescription: L10n.string(.Finder.requestPayloadMismatch)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(payload.kind, forKey: .kind)
        try container.encode(context, forKey: .context)
        try container.encode(payload, forKey: .payload)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public var sourcePaths: [String] { payload.sourcePaths }
    public var targetPath: String? { payload.targetPath }
    public var targetResolutionPolicy: FinderTargetResolutionPolicy { payload.targetResolutionPolicy }
}
