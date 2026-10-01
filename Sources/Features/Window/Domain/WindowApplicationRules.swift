import ArcKitPlatform
import Foundation

public struct WindowExcludedApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var bundleIdentifier: String

    public init(id: UUID = UUID(), displayName: String, bundleIdentifier: String) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
    }

    public static func excludedApplication(
        displayName: String,
        bundleIdentifier: String,
        currentBundleIdentifier: String?
    ) throws -> WindowExcludedApplication {
        let sanitizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedDisplayName.isEmpty, !sanitizedBundleIdentifier.isEmpty else {
            throw WindowExcludedApplicationValidationError.missingRequiredIdentity
        }
        guard sanitizedBundleIdentifier != currentBundleIdentifier,
              sanitizedBundleIdentifier != ArcKitConstants.appBundleIdentifier
        else {
            throw WindowExcludedApplicationValidationError.currentApplicationRejected
        }
        return WindowExcludedApplication(displayName: sanitizedDisplayName, bundleIdentifier: sanitizedBundleIdentifier)
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let decodedDisplayName = try container.decode(String.self, forKey: .displayName)
        let decodedBundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        guard decodedDisplayName == decodedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodedDisplayName.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayName,
                in: container,
                debugDescription: L10n.string(.Window.appRulesEmptyName)
            )
        }
        guard decodedBundleIdentifier == decodedBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodedBundleIdentifier.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifier,
                in: container,
                debugDescription: L10n.string(.Window.appRulesEmptyBundleID)
            )
        }
        guard decodedBundleIdentifier != ArcKitConstants.appBundleIdentifier else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIdentifier,
                in: container,
                debugDescription: L10n.string(.Window.validationSelfExclusionRejected)
            )
        }
        displayName = decodedDisplayName
        bundleIdentifier = decodedBundleIdentifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
    }
}

public enum WindowExcludedApplicationValidationError: Error, LocalizedError, Equatable, Sendable {
    case missingRequiredIdentity
    case currentApplicationRejected

    public var errorDescription: String? {
        switch self {
        case .missingRequiredIdentity: L10n.string(.Window.appRulesBundleIDRequired)
        case .currentApplicationRejected: L10n.string(.Window.appRulesSelfExclusionRejected)
        }
    }
}

public enum WindowExcludedApplicationAdditionResult: Equatable, Sendable {
    case inserted(WindowExcludedApplication)
    case alreadyExists(WindowExcludedApplication)
}

public struct AppConfigurationCandidate: Codable, Equatable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String
    public var processIdentifier: Int32

    public init(displayName: String, bundleIdentifier: String, processIdentifier: Int32) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

public enum AppConfigurationCandidateResolver: Sendable {
    public static func resolve(
        frontmost: AppConfigurationCandidate?,
        lastExternal: AppConfigurationCandidate?,
        currentBundleIdentifier: String?
    ) -> AppConfigurationCandidate? {
        if let frontmost, isValidCandidate(frontmost, currentBundleIdentifier: currentBundleIdentifier) {
            return frontmost
        }
        if let lastExternal, isValidCandidate(lastExternal, currentBundleIdentifier: currentBundleIdentifier) {
            return lastExternal
        }
        return nil
    }

    private static func isValidCandidate(
        _ snapshot: AppConfigurationCandidate,
        currentBundleIdentifier: String?
    ) -> Bool {
        guard snapshot.displayName == snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshot.displayName.isEmpty,
              snapshot.bundleIdentifier == snapshot.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshot.bundleIdentifier.isEmpty
        else { return false }
        return snapshot.bundleIdentifier != currentBundleIdentifier
            && snapshot.bundleIdentifier != ArcKitConstants.appBundleIdentifier
    }
}
