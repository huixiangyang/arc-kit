import ArcKitPlatform
import Foundation

public struct MouseAppScrollProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var bundleIdentifier: String?
    public var behavior: MouseAppScrollBehavior
    public var tuning: MouseScrollTuning
    public var note: String

    /// 预置为普通应用规则；运行时不硬编码旁路，用户修改或删除后以保存值为准。
    public static var uuRemoteDefault: Self {
        Self(
            id: UUID(uuidString: "CFA79D3A-D9EF-405C-A01F-6694262223BE")!,
            displayName: L10n.string(.Mouse.appProfileUuRemote),
            bundleIdentifier: "com.netease.uuremote",
            behavior: .system,
            note: L10n.string(.Mouse.appProfileUuRemoteNote)
        )
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        behavior: MouseAppScrollBehavior = .inherit,
        tuning: MouseScrollTuning = .defaults,
        note: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.behavior = behavior
        self.tuning = tuning
        self.note = note
    }

    public static func appProfile(
        displayName: String,
        bundleIdentifier: String?,
        tuning: MouseScrollTuning = .defaults,
        currentBundleIdentifier: String?
    ) throws -> MouseAppScrollProfile {
        let sanitizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedDisplayName.isEmpty,
              let sanitizedBundleIdentifier,
              !sanitizedBundleIdentifier.isEmpty
        else {
            throw MouseAppProfileValidationError.missingRequiredIdentity
        }
        guard sanitizedBundleIdentifier != currentBundleIdentifier,
              sanitizedBundleIdentifier != ArcKitConstants.appBundleIdentifier
        else {
            throw MouseAppProfileValidationError.currentApplicationRejected
        }
        return MouseAppScrollProfile(
            displayName: sanitizedDisplayName,
            bundleIdentifier: sanitizedBundleIdentifier,
            behavior: .inherit,
            tuning: tuning
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case bundleIdentifier
        case behavior
        case tuning
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDisplayName = try container.decode(String.self, forKey: .displayName)
        guard decodedDisplayName == decodedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodedDisplayName.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayName,
                in: container,
                debugDescription: L10n.string(.Mouse.appProfileInvalidName)
            )
        }
        let decodedBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        if let decodedBundleIdentifier,
           (decodedBundleIdentifier != decodedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                || decodedBundleIdentifier.isEmpty) {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifier,
                in: container,
                debugDescription: L10n.string(.Mouse.appProfileInvalidBundleID)
            )
        }

        id = try container.decode(UUID.self, forKey: .id)
        displayName = decodedDisplayName
        bundleIdentifier = decodedBundleIdentifier
        behavior = try container.decode(MouseAppScrollBehavior.self, forKey: .behavior)
        tuning = try container.decode(MouseScrollTuning.self, forKey: .tuning)
        note = try container.decode(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(tuning, forKey: .tuning)
        try container.encode(note, forKey: .note)
    }
}

public enum MouseAppProfileValidationError: Error, LocalizedError, Equatable, Sendable {
    case missingRequiredIdentity
    case currentApplicationRejected

    public var errorDescription: String? {
        switch self {
        case .missingRequiredIdentity:
            L10n.string(.Mouse.appProfileBundleIDRequired)
        case .currentApplicationRejected:
            L10n.string(.Mouse.appProfileSelfProfileRejected)
        }
    }
}


/// “跟随全局”是实时继承，不是添加规则时复制一份参数。
public enum MouseAppScrollBehavior: String, Codable, CaseIterable, Sendable {
    case inherit, custom, system
    public var title: String {
        switch self {
        case .inherit: L10n.string(.Mouse.appProfileFollowGlobal)
        case .custom: L10n.string(.Mouse.appProfileCustomSettings)
        case .system: L10n.string(.Mouse.appProfileUseSystemScrolling)
        }
    }
}
