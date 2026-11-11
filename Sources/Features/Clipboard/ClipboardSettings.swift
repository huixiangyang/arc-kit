import ArcKitPlatform
import Foundation

public enum ClipboardSyncScope: String, Codable, CaseIterable, Sendable {
    case favorites, history
}

/// 记录与同步分别选择；升级不会自动读取剪贴板，也不会自动上传既有内容。
public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var syncEnabled = false
    public var syncScope: ClipboardSyncScope = .favorites
    public var retentionDays = 7
    public var shortcut = HotKeyChord.disabled
    public var excludedApplications: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.keepassium.KeePassium",
    ]
    public static let defaults = ClipboardSettings()
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, syncEnabled, syncScope, retentionDays, shortcut, excludedApplications
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(syncEnabled, forKey: .syncEnabled)
        try values.encode(syncScope, forKey: .syncScope)
        try values.encode(retentionDays, forKey: .retentionDays)
        try values.encode(shortcut, forKey: .shortcut)
        // 设置备份执行规范化 JSON 回读；集合必须按固定顺序编码。
        try values.encode(excludedApplications.sorted(), forKey: .excludedApplications)
    }

    func validate() throws {
        guard [1, 7, 30].contains(retentionDays),
              !shortcut.isEnabled || shortcut.isSafeGlobalShortcut,
              excludedApplications.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains(where: \.isWhitespace) })
        else { throw ClipboardError.invalidSettings }
    }

    static let recordLayout = ArcKitRecordLayout("clipboard_preferences",
        fields: ["isEnabled", "syncEnabled", "syncScope", "retentionDays", "shortcut", "excludedApplications"],
        json: ["shortcut", "excludedApplications"])
}

enum ClipboardError: LocalizedError {
    case invalidSettings, invalidContent, unavailable, accountChanged, signedOut, invalidCloudRecord
    case noFinderWindow, pasteTargetLost, pastePermission, busy
    var errorDescription: String? {
        switch self {
        case .invalidSettings: L10n.string(.Clipboard.invalidSettings)
        case .invalidContent: L10n.string(.Clipboard.invalidContent)
        case .unavailable: L10n.string(.Clipboard.unavailable)
        case .accountChanged: L10n.string(.Clipboard.accountChanged)
        case .signedOut: L10n.string(.Clipboard.signedOut)
        case .invalidCloudRecord: L10n.string(.Clipboard.invalidCloudRecord)
        case .noFinderWindow: L10n.string(.Clipboard.noFinderWindow)
        case .pasteTargetLost: L10n.string(.Clipboard.pasteTargetLost)
        case .pastePermission: L10n.string(.Clipboard.pastePermission)
        case .busy: L10n.string(.Clipboard.busy)
        }
    }
}
