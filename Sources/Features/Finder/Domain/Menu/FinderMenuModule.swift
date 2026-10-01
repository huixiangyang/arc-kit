import ArcKitPlatform
import Foundation

public enum FinderMenuPresentationGroup: Int, Sendable {
    case creation, copyAndInfo, organization
}

/// 菜单功能目录是设置页与运行菜单的唯一来源；子动作只存在于动作契约中。
public enum FinderMenuModuleID: String, CaseIterable, Codable, Sendable, Identifiable {
    case newFile
    case favoriteApps
    case terminal
    case copyPath
    case copyFileName
    case favoriteDirectories
    case fileOrganization
    case fileInfo
    case copyHash
    case convertTo
    case folderIcon
    case extractIcon
    case colorPicker
    case advancedTools

    public var id: String { rawValue }
    public var defaultTitle: String {
        switch self {
        case .newFile: L10n.string(.Finder.pageNewFile)
        case .favoriteApps: L10n.string(.Finder.moduleOpen)
        case .terminal: L10n.string(.Finder.moduleTerminal)
        case .copyPath: L10n.string(.Finder.commandCopyPath)
        case .copyFileName: L10n.string(.Finder.menuCopyFilename)
        case .favoriteDirectories: L10n.string(.Finder.pageFavoriteFolders)
        case .fileOrganization: L10n.string(.Finder.moduleOrganizeFiles)
        case .fileInfo: L10n.string(.Finder.commandCopyFileInfo)
        case .copyHash: L10n.string(.Finder.commandCopyChecksum)
        case .convertTo: L10n.string(.Finder.commandConvertImage)
        case .folderIcon: L10n.string(.Finder.moduleFolderIcon)
        case .extractIcon: L10n.string(.Finder.commandExtractIcon)
        case .colorPicker: L10n.string(.Finder.modulePickImageColor)
        case .advancedTools: L10n.string(.Finder.moduleAdvancedTools)
        }
    }
    public var defaultEnabled: Bool {
        switch self {
        case .newFile, .favoriteApps, .terminal, .copyPath, .copyFileName: true
        default: false
        }
    }
    public var defaultOrder: Int { Self.allCases.firstIndex(of: self)! }
    public var presentationGroup: FinderMenuPresentationGroup {
        switch self {
        case .newFile, .favoriteApps, .terminal, .favoriteDirectories: .creation
        case .copyPath, .copyFileName, .fileInfo, .copyHash: .copyAndInfo
        default: .organization
        }
    }
    public var icon: ArcIconName {
        switch self {
        case .newFile: .filePlus
        case .favoriteApps: .appWindow
        case .terminal: .terminal
        case .copyPath: .moveHorizontal
        case .copyFileName: .textCursorInput
        case .favoriteDirectories: .folder
        case .fileOrganization: .folderCog
        case .fileInfo: .circleInfo
        case .copyHash: .hash
        case .convertTo: .refreshCw
        case .folderIcon: .folderCog
        case .extractIcon: .image
        case .colorPicker: .pipette
        case .advancedTools: .wrench
        }
    }
}

public struct FinderMenuModuleConfiguration: Codable, Equatable, Sendable, Identifiable {
    public let moduleID: FinderMenuModuleID
    public var isEnabled: Bool
    public var sortOrder: Int
    public var id: FinderMenuModuleID { moduleID }
    public var displayName: String { moduleID.defaultTitle }

    public init(moduleID: FinderMenuModuleID, enabled: Bool? = nil, sortOrder: Int) {
        self.moduleID = moduleID
        self.isEnabled = enabled ?? moduleID.defaultEnabled
        self.sortOrder = sortOrder
    }

    private enum CodingKeys: String, CodingKey {
        case moduleID, sortOrder
        case isEnabled = "enabled"
    }
}
