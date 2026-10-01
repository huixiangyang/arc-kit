import ArcKitPlatform
import Foundation

/// 主题配方只包含可验证的数据；配色的第一项为底色，后续为光源色。
struct AuraTheme: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var form: AuraForm
    var light: [UInt32]
    var dark: [UInt32]
    var seed: Int
    var spread: Double
    var x: Double
    var y: Double
    var motion: AuraMotion
    var particles: Double
    var grain: Double

    var title: String {
        switch id {
        case "amber": L10n.string(.AppBackground.auraAmber)
        case "mist": L10n.string(.AppBackground.auraMist)
        case "dusk": L10n.string(.AppBackground.auraDusk)
        case "aurora": L10n.string(.AppBackground.auraAurora)
        case "glacier": L10n.string(.AppBackground.auraGlacier)
        case "ink": L10n.string(.AppBackground.auraInk)
        default: name
        }
    }
    func validated() throws -> Self {
        guard (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.builtinIDs.contains(id)),
              name.count <= 80, Self.builtinIDs.contains(id) || UUID(uuidString: id) != nil,
              (3...5).contains(light.count), (3...5).contains(dark.count),
              (light + dark).allSatisfy({ $0 <= 0xFFFFFF }), (0...999_999).contains(seed),
              spread.isFinite, (0.5...1.5).contains(spread),
              particles.isFinite, (0...1).contains(particles), grain.isFinite, (0...1).contains(grain),
              x.isFinite, y.isFinite, (-0.4...0.4).contains(x), (-0.4...0.4).contains(y) else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.auraInvalid))
        }
        return self
    }
    static let builtinIDs: Set<String> = ["amber", "mist", "dusk", "aurora", "glacier", "ink"]
    static let builtins: [Self] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: AuraResourceLocator.self)
        #endif
        // 内置配方是产品必需资源，缺失必须暴露为打包故障。
        guard let url = bundle.url(forResource: "Themes", withExtension: "json", subdirectory: "Aura"),
              let data = try? Data(contentsOf: url), let themes = try? JSONDecoder().decode([Self].self, from: data),
              Set(themes.map(\.id)) == builtinIDs, themes.count == builtinIDs.count,
              themes.allSatisfy({ (try? $0.validated()) != nil }) else { preconditionFailure("Invalid bundled Aura themes") }
        return themes
    }()
    static var amber: Self { builtins[0] }
}
private final class AuraResourceLocator: NSObject {}

enum AuraForm: String, Codable, CaseIterable, Sendable {
    case glow, mist, ribbon
    var title: String {
        switch self {
        case .glow: L10n.string(.AppBackground.auraGlow)
        case .mist: L10n.string(.AppBackground.auraFog)
        case .ribbon: L10n.string(.AppBackground.auraRibbon)
        }
    }
}
enum AuraMotion: String, Codable, CaseIterable, Sendable {
    case still, slow, standard
    var rate: Double { switch self { case .still: 0; case .slow: 0.45; case .standard: 1 } }
    var title: String { switch self {
    case .still: L10n.string(.AppBackground.auraStill)
    case .slow: L10n.string(.AppBackground.auraSlow)
    case .standard: L10n.string(.AppBackground.auraStandard)
    } }
}
enum AuraAutomation: String, Codable, CaseIterable, Sendable {
    case manual, appearance, schedule
    var title: String { switch self {
    case .manual: L10n.string(.AppBackground.auraManual)
    case .appearance: L10n.string(.AppBackground.auraAppearance)
    case .schedule: L10n.string(.AppBackground.auraSchedule)
    } }
}

struct AuraSettings: Codable, Equatable, Sendable {
    var themeID = "amber"
    var draft: AuraTheme? = nil
    var parallax = false
    var automation: AuraAutomation = .manual
    var dayThemeID = "amber"
    var nightThemeID = "ink"
    var dayStart = 7 * 60
    var nightStart = 19 * 60
    var manualOverride = false
    var favorites: [String] = []

    func resolvedID(at date: Date, dark: Bool, calendar: Calendar = .current) -> String {
        guard !manualOverride else { return themeID }
        switch automation {
        case .manual: return themeID
        case .appearance: return dark ? nightThemeID : dayThemeID
        case .schedule:
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let day = dayStart < nightStart ? (dayStart..<nightStart).contains(minute)
                : minute >= dayStart || minute < nightStart
            return day ? dayThemeID : nightThemeID
        }
    }
    func resolved(in themes: [AuraTheme], at date: Date = Date(), dark: Bool) -> AuraTheme {
        let id = resolvedID(at: date, dark: dark)
        if let draft, draft.id == id { return draft }
        return (AuraTheme.builtins + themes).first(where: { $0.id == id }) ?? .amber
    }
    func validate(themes: [AuraTheme]) throws {
        let ids = AuraTheme.builtinIDs.union(themes.map(\.id))
        guard themes.count <= 60, Set(themes.map(\.id)).count == themes.count,
              themes.allSatisfy({ !AuraTheme.builtinIDs.contains($0.id) }),
              [themeID, dayThemeID, nightThemeID].allSatisfy(ids.contains),
              (0..<1440).contains(dayStart), (0..<1440).contains(nightStart), dayStart != nightStart,
              Set(favorites).count == favorites.count, favorites.allSatisfy(ids.contains),
              draft == nil || draft?.id == themeID else { throw AppBackgroundError.message(L10n.string(.AppBackground.auraInvalid)) }
        for theme in themes { _ = try theme.validated() }
        if let draft { _ = try draft.validated() }
    }
    mutating func select(_ id: String) {
        themeID = id; draft = nil
        manualOverride = automation != .manual
    }
}

/// 分享格式独立版本；不携带可执行内容、文件路径或应用的其他设置。
struct AuraThemeDocument: Codable, Sendable {
    let format: String
    let version: Int
    let theme: AuraTheme
    init(theme: AuraTheme) { format = "arc-kit-aura"; version = 1; self.theme = theme }
    static func decode(_ data: Data) throws -> AuraTheme {
        guard data.count <= 65_536, let document = try? JSONDecoder().decode(Self.self, from: data),
              document.format == "arc-kit-aura", document.version == 1 else {
            throw AppBackgroundError.message(L10n.string(.AppBackground.auraFileInvalid))
        }
        return try document.theme.validated()
    }
}

/// 相位只累计实际播放的时间，失活、节能和调速不会跳到墙上时钟对应的另一帧。
struct AuraPhase: Equatable {
    private(set) var time = 0.0
    mutating func advance(seconds: Double, rate: Double) {
        guard seconds.isFinite, rate.isFinite, seconds >= 0, rate > 0 else { return }
        time += min(seconds, 0.1) * rate
    }
}
