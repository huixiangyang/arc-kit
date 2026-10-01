import ArcKitPlatform
import Foundation

/// 窗口能力的持久化配置；动作定义、快捷键、候选过滤和几何算法分别维护。
public struct WindowManagementSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var hotKeysEnabled: Bool
    public var dragSnapEnabled: Bool
    public var showSnapPreview: Bool
    public var windowGap: Double
    public var displayNavigationStrategy: WindowDisplayNavigationStrategy
    public var bindings: [WindowHotKeyBinding]
    public var excludedApplications: [WindowExcludedApplication]

    public init(
        isEnabled: Bool = true,
        hotKeysEnabled: Bool = true,
        dragSnapEnabled: Bool = true,
        showSnapPreview: Bool = true,
        windowGap: Double = 0,
        displayNavigationStrategy: WindowDisplayNavigationStrategy = .spatialOrder,
        bindings: [WindowHotKeyBinding] = WindowHotKeyBinding.magnetDefaults,
        excludedApplications: [WindowExcludedApplication] = []
    ) {
        self.isEnabled = isEnabled
        self.hotKeysEnabled = hotKeysEnabled
        self.dragSnapEnabled = dragSnapEnabled
        self.showSnapPreview = showSnapPreview
        self.windowGap = windowGap
        self.displayNavigationStrategy = displayNavigationStrategy
        self.bindings = bindings
        self.excludedApplications = excludedApplications
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case hotKeysEnabled
        case dragSnapEnabled
        case showSnapPreview
        case windowGap
        case displayNavigationStrategy
        case bindings
        case excludedApplications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBindings = try container.decode([WindowHotKeyBinding].self, forKey: .bindings)
        try Self.validateDecodedBindings(decodedBindings)

        let decodedGap = try container.decode(Double.self, forKey: .windowGap)
        guard decodedGap.isFinite, decodedGap >= 0, decodedGap <= 64 else {
            throw DecodingError.dataCorruptedError(
                forKey: .windowGap,
                in: container,
                debugDescription: L10n.string(.Window.validationWindowSpacingOutsideCurrentSchema)
            )
        }

        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        hotKeysEnabled = try container.decode(Bool.self, forKey: .hotKeysEnabled)
        dragSnapEnabled = try container.decode(Bool.self, forKey: .dragSnapEnabled)
        showSnapPreview = try container.decode(Bool.self, forKey: .showSnapPreview)
        windowGap = decodedGap
        displayNavigationStrategy = try container.decode(WindowDisplayNavigationStrategy.self, forKey: .displayNavigationStrategy)
        bindings = decodedBindings
        let decodedExcludedApplications = try container.decode([WindowExcludedApplication].self, forKey: .excludedApplications)
        try Self.validateDecodedExcludedApplications(decodedExcludedApplications)
        excludedApplications = decodedExcludedApplications
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(hotKeysEnabled, forKey: .hotKeysEnabled)
        try container.encode(dragSnapEnabled, forKey: .dragSnapEnabled)
        try container.encode(showSnapPreview, forKey: .showSnapPreview)
        try container.encode(windowGap, forKey: .windowGap)
        try container.encode(displayNavigationStrategy, forKey: .displayNavigationStrategy)
        try container.encode(bindings, forKey: .bindings)
        try container.encode(excludedApplications, forKey: .excludedApplications)
    }

    public static let defaults = WindowManagementSettings()

    public func binding(for action: WindowLayoutAction) -> WindowHotKeyBinding? {
        bindings.first { $0.action == action }
    }

    /// 快捷键是用户配置的动作子集；首次录制直接新增，不要求为新布局补齐占位配置。
    public mutating func setBinding(_ binding: WindowHotKeyBinding) {
        if let index = bindings.firstIndex(where: { $0.action == binding.action }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
    }

    public func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// 排除列表的唯一性由 Core 原子维护；重复添加只返回原项目，绝不改名或重排。
    @discardableResult
    public mutating func addExcludedApplication(
        _ application: WindowExcludedApplication
    ) throws -> WindowExcludedApplicationAdditionResult {
        guard application.displayName == application.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              application.bundleIdentifier == application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw WindowExcludedApplicationValidationError.missingRequiredIdentity
        }
        let validated = try WindowExcludedApplication.excludedApplication(
            displayName: application.displayName,
            bundleIdentifier: application.bundleIdentifier,
            currentBundleIdentifier: ArcKitConstants.appBundleIdentifier
        )
        if let existing = excludedApplications.first(where: {
            $0.bundleIdentifier == validated.bundleIdentifier
        }) {
            return .alreadyExists(existing)
        }
        excludedApplications.append(application)
        return .inserted(application)
    }

    public func duplicateEnabledBindings() -> [WindowHotKeyBinding] {
        hotKeyRegistrationPlan().duplicateBindings
    }

    public func duplicateEnabledActions() -> Set<WindowLayoutAction> {
        Set(duplicateEnabledBindings().map(\.action))
    }

    public func hotKeyRegistrationPlan() -> WindowHotKeyRegistrationPlan {
        var seen: Set<String> = []
        var valid: [WindowHotKeyBinding] = []
        var unsafe: [WindowHotKeyBinding] = []
        var duplicates: [WindowHotKeyBinding] = []
        for binding in bindings where binding.isEnabled {
            guard binding.isSafeGlobalShortcut else {
                unsafe.append(binding)
                continue
            }
            let key = binding.shortcutIdentifier
            if seen.contains(key) {
                duplicates.append(binding)
            } else {
                seen.insert(key)
                valid.append(binding)
            }
        }
        return WindowHotKeyRegistrationPlan(
            validBindings: valid,
            unsafeBindings: unsafe,
            duplicateBindings: duplicates
        )
    }

    private static func validateDecodedBindings(_ bindings: [WindowHotKeyBinding]) throws {
        let actions = bindings.map(\.action)
        let actionSet = Set(actions)
        guard actions.count == actionSet.count else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.bindings],
                debugDescription: L10n.string(.Window.validationEachWindowActionOne)
            ))
        }
    }

    private static func validateDecodedExcludedApplications(_ applications: [WindowExcludedApplication]) throws {
        var bundleIdentifiers: Set<String> = []
        for application in applications {
            let displayName = application.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleIdentifier = application.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, !bundleIdentifier.isEmpty else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.excludedApplications],
                    debugDescription: L10n.string(.Window.validationExcludedWindowAppsRequireNonemptyName)
                ))
            }
            guard displayName == application.displayName,
                  bundleIdentifier == application.bundleIdentifier
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.excludedApplications],
                    debugDescription: L10n.string(.Window.validationExcludedWindowAppNamesBundleIDs)
                ))
            }
            guard bundleIdentifier != ArcKitConstants.appBundleIdentifier else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.excludedApplications],
                    debugDescription: L10n.string(.Window.validationSelfExclusionRejected)
                ))
            }
            guard bundleIdentifiers.insert(bundleIdentifier).inserted else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.excludedApplications],
                    debugDescription: L10n.string(.Window.validationExcludedWindowAppBundleIDs)
                ))
            }
        }
    }
}

public extension WindowManagementSettings {
    static let recordLayout = ArcKitRecordLayout("window_preferences", fields: ["isEnabled", "hotKeysEnabled", "dragSnapEnabled", "showSnapPreview", "windowGap", "displayNavigationStrategy"], children: [
        "bindings": ArcKitRecordLayout("window_hotkeys", fields: ["action", "keyCode", "keyEquivalent", "modifiers", "isEnabled"], json: ["modifiers"]),
        "excludedApplications": ArcKitRecordLayout("window_application_rules", fields: ["id", "displayName", "bundleIdentifier"])
    ])
}
