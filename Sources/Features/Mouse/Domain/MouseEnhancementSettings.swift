import ArcKitPlatform
import Foundation

public enum MouseScrollScope: String, Codable, CaseIterable, Sendable {
    case allApplications, selectedApplications
    public var title: String { self == .allApplications ? L10n.string(.Mouse.validationAllApps) : L10n.string(.Mouse.validationListedApps) }
}

public struct MouseEnhancementSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var scrollScope: MouseScrollScope
    public var globalTuning: MouseScrollTuning
    public var appProfiles: [MouseAppScrollProfile]
    public var gestureSettings: MouseGestureSettings

    public init(isEnabled: Bool = true, scrollScope: MouseScrollScope = .allApplications,
                globalTuning: MouseScrollTuning = .defaults, appProfiles: [MouseAppScrollProfile] = [.uuRemoteDefault],
                gestureSettings: MouseGestureSettings = .defaults) {
        self.isEnabled = isEnabled
        self.scrollScope = scrollScope
        self.globalTuning = globalTuning
        self.appProfiles = appProfiles
        self.gestureSettings = gestureSettings
    }
    public static let defaults = MouseEnhancementSettings()
    public var enabledAppProfileCount: Int { appProfiles.filter { $0.behavior != .system }.count }

    /// 说明只用于管理规则；编辑文字不能重建后台会话或打断平滑滚动。
    public func hasSameRuntimeConfiguration(as other: Self) -> Bool {
        guard appProfiles.count == other.appProfiles.count else { return false }
        var candidate = self
        for index in candidate.appProfiles.indices {
            candidate.appProfiles[index].note = other.appProfiles[index].note
        }
        return candidate == other
    }

    /// 添加 App Profile 时由鼠标配置维护唯一性，重复添加只能返回既有配置，禁止静默覆盖用户参数。
    @discardableResult
    public mutating func addAppProfile(
        _ profile: MouseAppScrollProfile
    ) throws -> MouseAppProfileAdditionResult {
        let normalizedName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleIdentifier = profile.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName == profile.displayName,
              !normalizedName.isEmpty,
              let normalizedBundleIdentifier,
              normalizedBundleIdentifier == profile.bundleIdentifier,
              !normalizedBundleIdentifier.isEmpty
        else {
            throw MouseAppProfileValidationError.missingRequiredIdentity
        }
        guard normalizedBundleIdentifier != ArcKitConstants.appBundleIdentifier else {
            throw MouseAppProfileValidationError.currentApplicationRejected
        }
        if let existing = appProfiles.first(where: { $0.bundleIdentifier == normalizedBundleIdentifier }) {
            return .alreadyExists(existing)
        }
        appProfiles.append(profile)
        return .inserted(profile)
    }


    /// 删除最后一条规则也不扩大作用范围；空的指定列表表示没有应用被增强。
    public mutating func removeAppProfile(id: UUID) {
        appProfiles.removeAll { $0.id == id }
    }

    public func effectiveTuning(for bundleIdentifier: String?) -> MouseScrollTuning? {
        guard isEnabled else { return nil }
        if let rule = appProfiles.first(where: { $0.bundleIdentifier == bundleIdentifier && bundleIdentifier != nil }) {
            switch rule.behavior {
            case .inherit: return globalTuning
            case .custom: return rule.tuning
            case .system: return nil
            }
        }
        return scrollScope == .allApplications ? globalTuning : nil
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, scrollScope, globalTuning, appProfiles, gestureSettings
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        scrollScope = try container.decode(MouseScrollScope.self, forKey: .scrollScope)
        globalTuning = try container.decode(MouseScrollTuning.self, forKey: .globalTuning)
        appProfiles = try container.decode([MouseAppScrollProfile].self, forKey: .appProfiles)
        try Self.validateAppProfiles(appProfiles)
        gestureSettings = try container.decode(MouseGestureSettings.self, forKey: .gestureSettings)
    }
    private static func validateAppProfiles(_ profiles: [MouseAppScrollProfile]) throws {
        var bundleIdentifiers: Set<String> = []
        var ids: Set<UUID> = []
        for profile in profiles {
            guard let bundleIdentifier = profile.bundleIdentifier,
                  !bundleIdentifier.isEmpty
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.appProfiles],
                    debugDescription: L10n.string(.Mouse.validationAppBundleIDRequired)
                ))
            }
            guard bundleIdentifier != ArcKitConstants.appBundleIdentifier else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.appProfiles],
                    debugDescription: L10n.string(.Mouse.validationSelfProfileRejected)
                ))
            }
            guard bundleIdentifiers.insert(bundleIdentifier).inserted else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.appProfiles],
                    debugDescription: L10n.string(.Mouse.validationMouseAppProfileBundleIDs)
                ))
            }
            guard ids.insert(profile.id).inserted else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.appProfiles],
                    debugDescription: L10n.string(.Mouse.validationMouseAppProfileIdsUnique)
                ))
            }
        }
    }

}

public enum MouseAppProfileAdditionResult: Equatable, Sendable {
    case inserted(MouseAppScrollProfile)
    case alreadyExists(MouseAppScrollProfile)
}

public extension MouseEnhancementSettings {
    static let recordLayout = ArcKitRecordLayout("mouse_preferences", fields: ["isEnabled", "scrollScope", "globalTuning", "gestureSettings"], json: ["globalTuning", "gestureSettings"], children: [
        "appProfiles": ArcKitRecordLayout("mouse_application_rules", fields: ["id", "displayName", "bundleIdentifier", "behavior", "tuning", "note"], json: ["tuning"])
    ])
}
