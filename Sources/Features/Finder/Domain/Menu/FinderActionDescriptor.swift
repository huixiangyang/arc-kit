import ArcKitPlatform
import Foundation

public enum FinderActionExecutionMode: String, Codable, Sendable {
    case agent
    case extensionLocal
}

/// Finder 菜单项与点击动作之间的唯一契约。
///
/// 扩展生成菜单时只把这个结构写入 `NSMenuItem.representedObject`，点击后再由
/// `FinderCommandRequestFactory` 根据 descriptor 构造强类型命令。这样菜单展示、点击分发和
/// Agent 执行之间不再依赖标题、UUID 或当前设置二次反查。
public struct FinderActionDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var actionID: String
    public var title: String
    public var moduleID: FinderMenuModuleID
    public var actionKind: FinderMenuActionKind
    public var commandKind: FinderCommandKind
    public var payload: FinderActionDescriptorPayload
    public var visibilityRule: FinderActionVisibilityRule
    public var icon: ArcIconName?
    public var isEnabled: Bool
    public var disabledReason: String?

    public var id: String { actionID }

    public init(
        actionID: String,
        title: String,
        moduleID: FinderMenuModuleID,
        actionKind: FinderMenuActionKind,
        commandKind: FinderCommandKind,
        payload: FinderActionDescriptorPayload = .none,
        visibilityRule: FinderActionVisibilityRule = .resolvedTarget,
        icon: ArcIconName? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil
    ) {
        self.actionID = actionID
        self.title = title
        self.moduleID = moduleID
        self.actionKind = actionKind
        self.commandKind = commandKind
        self.payload = payload
        self.visibilityRule = visibilityRule
        self.icon = icon
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }

    private enum CodingKeys: String, CodingKey {
        case actionID, title, moduleID, actionKind, commandKind, payload, visibilityRule
        case icon, isEnabled, disabledReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try container.decode(String.self, forKey: .actionID)
        title = try container.decode(String.self, forKey: .title)
        moduleID = try container.decode(FinderMenuModuleID.self, forKey: .moduleID)
        actionKind = try container.decode(FinderMenuActionKind.self, forKey: .actionKind)
        commandKind = try container.decode(FinderCommandKind.self, forKey: .commandKind)
        payload = try container.decode(FinderActionDescriptorPayload.self, forKey: .payload)
        visibilityRule = try container.decode(FinderActionVisibilityRule.self, forKey: .visibilityRule)
        icon = try container.decodeIfPresent(ArcIconName.self, forKey: .icon)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        disabledReason = try container.decodeIfPresent(String.self, forKey: .disabledReason)

        try Self.validateStrictString(actionID, forKey: .actionID, fieldName: L10n.string(.Finder.actionFinderActionId), container: container)
        try Self.validateStrictString(title, forKey: .title, fieldName: L10n.string(.Finder.actionFinderActionTitle), container: container)
        if let disabledReason {
            try Self.validateStrictString(disabledReason, forKey: .disabledReason, fieldName: L10n.string(.Finder.actionFinderActionDisabledReason), container: container)
        }
    }

    private static func validateStrictString(
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

/// Finder 菜单项在不同右键上下文中的展示规则。
///
/// 这里只表达“是否应该展示”，实际点击后仍由扩展和 Agent 做二次校验，
/// 防止 Finder 回调上下文变化导致误操作。
public enum FinderActionVisibilityRule: String, Codable, Equatable, Sendable, CaseIterable {
    /// 当前目录类动作：Finder 空白处，或选中文件夹时以该文件夹作为目标。
    case currentDirectoryTarget
    /// 终端允许进入单个文件的父目录；多选时不能静默选择第一项。
    case terminalDirectoryTarget
    /// 可解析目标动作：空白处、文件、文件夹、图片、混选都可出现。
    case resolvedTarget
    /// 任意选中项动作：必须有选择，混选也允许。
    case selectedItems
    /// 文件专用动作：所有选中项都必须是文件。
    case selectedFiles
    /// 文件夹专用动作：所有选中项都必须是文件夹。
    case selectedFolders
    /// 图片专用动作：所有选中项都必须是图片文件。
    case selectedImages
    case singleItem
    case singleImage
    /// 无条件展示。
    case always
}

public enum FinderMenuTargetKind: String, Codable, Equatable, Sendable, CaseIterable {
    case blank
    case files
    case folders
    case images
    case mixed
}

public struct FinderMenuTargetContext: Codable, Equatable, Sendable {
    public var kind: FinderMenuTargetKind
    public var selectedItemCount: Int
    public var hasCurrentDirectory: Bool

    public init(kind: FinderMenuTargetKind, selectedItemCount: Int = 0, hasCurrentDirectory: Bool? = nil) {
        self.kind = kind
        self.selectedItemCount = selectedItemCount
        self.hasCurrentDirectory = hasCurrentDirectory ?? (kind == .blank || (kind == .folders && selectedItemCount == 1))
    }

    public var hasSelection: Bool {
        selectedItemCount > 0
    }

    public var canUseCurrentDirectoryTarget: Bool {
        hasCurrentDirectory && (kind == .blank || (kind == .folders && selectedItemCount == 1))
    }

    public var hasResolvedTarget: Bool {
        hasCurrentDirectory || hasSelection
    }
}

public extension FinderActionVisibilityRule {
    func isVisible(in context: FinderMenuTargetContext) -> Bool {
        switch self {
        case .currentDirectoryTarget:
            return context.canUseCurrentDirectoryTarget
        case .terminalDirectoryTarget:
            return context.canUseCurrentDirectoryTarget || (context.selectedItemCount == 1 && context.kind != .mixed)
        case .resolvedTarget:
            return context.hasResolvedTarget
        case .selectedItems:
            return context.hasSelection
        case .selectedFiles:
            return context.hasSelection && (context.kind == .files || context.kind == .images)
        case .selectedFolders:
            return context.hasSelection && context.kind == .folders
        case .selectedImages:
            return context.hasSelection && context.kind == .images
        case .singleItem:
            return context.selectedItemCount == 1
        case .singleImage:
            return context.selectedItemCount == 1 && context.kind == .images
        case .always:
            return true
        }
    }
}

public enum FinderMenuActionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case showArcKitRecoveryInfo
    case createNewFile
    case copyPaths
    case copyFileNames
    case copyFileInfo
    case copyPickedColor
    case copyHash
    case openTerminal
    case openWithApp
    case copyToDirectory
    case moveToDirectory
    case openPath
    case setFolderIcon
    case restoreFolderIcon
    case extractIcon
    case hideFiles
    case lockFiles
    case deleteFiles
    case archiveFiles
    case moveIntoFolder
    case batchRename
    case hideAllExceptFiles
    case showHiddenFilesInfo
    case runScript
    case convertImage
    case flattenFolder
}

public enum FinderActionDescriptorPayload: Codable, Equatable, Sendable {
    case none
    case templateID(String)
    case favoriteApplication(FavoriteApplication)
    case path(String)
    case hashAlgorithm(FileHashAlgorithm)
    case terminal(FinderTerminalDescriptorPayload)
    case bool(Bool)
    case imageFormat(String)
    case folderName(String)

    private enum CodingKeys: String, CodingKey {
        case type, templateID, favoriteApplication, path, hashAlgorithm, terminal, boolValue, imageFormat, folderName
    }

    private enum PayloadType: String, Codable {
        case none, templateID, favoriteApplication, path, hashAlgorithm, terminal, bool, imageFormat, folderName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PayloadType.self, forKey: .type) {
        case .none:
            self = .none
        case .templateID:
            let value = try container.decode(String.self, forKey: .templateID)
            try Self.validateStrictString(value, forKey: .templateID, fieldName: L10n.string(.Finder.actionNewFileTemplateId), container: container)
            self = .templateID(value)
        case .favoriteApplication:
            self = .favoriteApplication(try container.decode(FavoriteApplication.self, forKey: .favoriteApplication))
        case .path:
            let value = try container.decode(String.self, forKey: .path)
            try Self.validateStrictString(value, forKey: .path, fieldName: L10n.string(.Finder.actionPathActionTarget), container: container)
            guard value.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: L10n.string(.Finder.actionPathActionTargetAbsolute)
                )
            }
            self = .path(value)
        case .hashAlgorithm:
            self = .hashAlgorithm(try container.decode(FileHashAlgorithm.self, forKey: .hashAlgorithm))
        case .terminal:
            self = .terminal(try container.decode(FinderTerminalDescriptorPayload.self, forKey: .terminal))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .boolValue))
        case .imageFormat:
            let value = try container.decode(String.self, forKey: .imageFormat)
            try Self.validateStrictString(value, forKey: .imageFormat, fieldName: L10n.string(.Finder.actionImageConversionFormat), container: container)
            self = .imageFormat(value)
        case .folderName:
            let value = try container.decode(String.self, forKey: .folderName)
            try Self.validateStrictString(value, forKey: .folderName, fieldName: L10n.string(.Finder.actionTargetFolderName), container: container)
            guard !value.contains("/"), !value.contains("\\") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .folderName,
                    in: container,
                    debugDescription: L10n.string(.Finder.actionInvalidFolderName)
                )
            }
            self = .folderName(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(PayloadType.none, forKey: .type)
        case let .templateID(value):
            try container.encode(PayloadType.templateID, forKey: .type)
            try container.encode(value, forKey: .templateID)
        case let .favoriteApplication(value):
            try container.encode(PayloadType.favoriteApplication, forKey: .type)
            try container.encode(value, forKey: .favoriteApplication)
        case let .path(value):
            try container.encode(PayloadType.path, forKey: .type)
            try container.encode(value, forKey: .path)
        case let .hashAlgorithm(value):
            try container.encode(PayloadType.hashAlgorithm, forKey: .type)
            try container.encode(value, forKey: .hashAlgorithm)
        case let .terminal(value):
            try container.encode(PayloadType.terminal, forKey: .type)
            try container.encode(value, forKey: .terminal)
        case let .bool(value):
            try container.encode(PayloadType.bool, forKey: .type)
            try container.encode(value, forKey: .boolValue)
        case let .imageFormat(value):
            try container.encode(PayloadType.imageFormat, forKey: .type)
            try container.encode(value, forKey: .imageFormat)
        case let .folderName(value):
            try container.encode(PayloadType.folderName, forKey: .type)
            try container.encode(value, forKey: .folderName)
        }
    }

    private static func validateStrictString(
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

public struct FinderTerminalDescriptorPayload: Codable, Equatable, Sendable {
    public var terminalApp: TerminalApp
    public var openMode: FinderTerminalOpenMode

    public init(terminalApp: TerminalApp, openMode: FinderTerminalOpenMode = .open) {
        self.terminalApp = terminalApp
        self.openMode = openMode
    }
}
