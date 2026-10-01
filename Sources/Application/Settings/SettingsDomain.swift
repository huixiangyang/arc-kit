import ArcKitFinder
import ArcKitPlatform
import ArcKitMouse
import ArcKitWindow
import Foundation

public struct GlobalSettings: Codable, Equatable, Sendable {
    public var language: ArcKitLanguage
    public var appearance: ArcAppearance
    public var reduceMotionEnabled: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool
    public var launchAtLoginEnabled: Bool

    public init(
        language: ArcKitLanguage = .system,
        appearance: ArcAppearance,
        reduceMotionEnabled: Bool,
        showDockIcon: Bool,
        showMenuBarIcon: Bool = true,
        launchAtLoginEnabled: Bool
    ) {
        self.language = language
        self.appearance = appearance
        self.reduceMotionEnabled = reduceMotionEnabled
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }

    public static let defaults = GlobalSettings(appSettings: .defaults)

    public init(appSettings: AppSettings) {
        language = appSettings.language
        appearance = appSettings.appearance
        reduceMotionEnabled = appSettings.reduceMotionEnabled
        showDockIcon = appSettings.showDockIcon
        showMenuBarIcon = appSettings.showMenuBarIcon
        launchAtLoginEnabled = appSettings.launchAtLoginEnabled
    }

    func apply(to settings: inout AppSettings) {
        settings.language = language
        settings.appearance = appearance
        settings.reduceMotionEnabled = reduceMotionEnabled
        settings.showDockIcon = showDockIcon
        settings.showMenuBarIcon = showMenuBarIcon
        settings.launchAtLoginEnabled = launchAtLoginEnabled
    }
}

public enum SettingsDomain: String, CaseIterable, Codable, Sendable {
    case global
    case window
    case mouse
    case finder

}

public enum SettingsRepositoryError: LocalizedError, Equatable {
    case writeFailed(SettingsDomain, String)
    case verificationFailed(SettingsDomain)
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(domain, message):
            L10n.string(.Settings.domainWriteFailed(String(describing: domain.rawValue), String(describing: message)))
        case let .verificationFailed(domain):
            L10n.string(.Settings.domainSettingsVerificationWritingFailed(String(describing: domain.rawValue)))
        case let .transactionFailed(message):
            L10n.string(.Settings.domainSettingsTransactionFailed(String(describing: message)))
        }
    }
}


extension GlobalSettings {
    static let recordLayout = ArcKitRecordLayout("app_preferences", fields: ["language", "appearance", "reduceMotionEnabled", "showDockIcon", "showMenuBarIcon", "launchAtLoginEnabled"])
}
