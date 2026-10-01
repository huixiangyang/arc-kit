import ArcKitPlatform
import ArcKitFinder
import Foundation

public enum FinderCommandExecutionError: LocalizedError {
    case missingValue(String)
    case featureDisabled(String)
    case missingTargetDirectory(String)
    case emptySelection
    case favoriteApplicationNotFound(UUID)
    case commandFailed(String)
    case imageLoadFailed(String)
    case applicationUnavailable(String)
    case unsupportedImageFormat(String)
    case targetResolutionFailed(String)
    case outputVerificationFailed(String)
    case operationVerificationFailed(String)
    case destructiveActionNotConfirmed(String)
    case partiallyCompleted(action: String, completedPaths: [String], reason: String)

    public var errorDescription: String? {
        switch self {
        case let .missingValue(name):
            L10n.string(.FinderActions.executionRequiredParameterMissing(String(describing: name)))
        case let .featureDisabled(message):
            message
        case let .missingTargetDirectory(action):
            L10n.string(.FinderActions.executionTargetMissing(String(describing: action)))
        case .emptySelection:
            L10n.string(.FinderActions.executionActionableFinderSelectionMissing)
        case let .favoriteApplicationNotFound(id):
            L10n.string(.FinderActions.executionFavoriteAppConfigurationMissing(String(describing: id.uuidString)))
        case let .commandFailed(command):
            L10n.string(.FinderActions.executionCommandFailed(String(describing: command)))
        case let .imageLoadFailed(path):
            L10n.string(.FinderActions.executionImageReadFailed(String(describing: path)))
        case let .applicationUnavailable(name):
            L10n.string(.FinderActions.executionAppMissingInstallRetry(String(describing: name)))
        case let .unsupportedImageFormat(format):
            L10n.string(.FinderActions.executionUnsupportedImage(String(describing: format)))
        case let .targetResolutionFailed(message):
            L10n.string(.FinderActions.executionCurrentFolderMissing(String(describing: message)))
        case let .outputVerificationFailed(path):
            L10n.string(.FinderActions.executionOutputFileMissingEmpty(String(describing: path)))
        case let .operationVerificationFailed(message):
            L10n.string(.FinderActions.executionUnconfirmed(String(describing: message)))
        case let .destructiveActionNotConfirmed(action):
            L10n.string(.FinderActions.executionUserConfirmationMissingExecutionDenied(String(describing: action)))
        case let .partiallyCompleted(action, completedPaths, reason):
            L10n.string(.FinderActions.executionInterruptedCompletedItemsPreserved(String(describing: action), String(describing: reason), String(describing: completedPaths.count), String(describing: completedPaths.joined(separator: "；"))))
        }
    }
}

public struct FinderResolvedTargetDirectory: Equatable, Sendable {
    public var path: String
    public var source: String

    public init(path: String, source: String) {
        self.path = path
        self.source = source
    }
}

public struct FinderCommandExecutionResult: Codable, Equatable, Sendable {
    public var clipboardText: String?
    public var clipboardResultKind: FinderClipboardResultKind?
    public var createdPaths: [String]
    public var userMessage: String?
    public var successFeedbackTitle: String?
    public var successFeedbackMessage: String?
    public var batchRenameReceipt: FinderBatchRenameExecutionReceipt?

    public init(
        clipboardText: String? = nil,
        clipboardResultKind: FinderClipboardResultKind? = nil,
        createdPaths: [String] = [],
        userMessage: String? = nil,
        successFeedbackTitle: String? = nil,
        successFeedbackMessage: String? = nil,
        batchRenameReceipt: FinderBatchRenameExecutionReceipt? = nil
    ) {
        self.clipboardText = clipboardText
        self.clipboardResultKind = clipboardResultKind
        self.createdPaths = createdPaths
        self.userMessage = userMessage
        self.successFeedbackTitle = successFeedbackTitle
        self.successFeedbackMessage = successFeedbackMessage
        self.batchRenameReceipt = batchRenameReceipt
    }
}
