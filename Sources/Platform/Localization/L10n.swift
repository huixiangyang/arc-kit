import Foundation

public enum ArcKitLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }
    // 使用语言本身的名称，误选语言后仍能找到切换入口。
    public var displayName: String {
        switch self {
        case .system: L10n.string(.Common.languageSystem)
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ArcKitLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            if identifier == "zh" || identifier.hasPrefix("zh-") { return .simplifiedChinese }
            if identifier == "en" || identifier.hasPrefix("en-") { return .english }
        }
        return .english
    }
    public var locale: Locale { Locale(identifier: resolved().rawValue) }
}

/// 只提供应用语言上下文；翻译查找、参数插值和复数规则全部由 Foundation 处理。
public enum L10n {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language: ArcKitLanguage = .system
    }
    private static let state = State()
    public static var language: ArcKitLanguage { state.lock.withLock { state.language } }
    public static var locale: Locale { language.locale }
    public static func configure(_ language: ArcKitLanguage) { state.lock.withLock { state.language = language } }

    public static func string(_ resource: LocalizedStringResource, language: ArcKitLanguage? = nil) -> String {
        var resource = resource
        resource.locale = (language ?? self.language).locale
        return String(localized: resource)
    }

    public static func fileSize(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(locale)) }
    public static func time(_ date: Date) -> String { date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(locale)) }
}
