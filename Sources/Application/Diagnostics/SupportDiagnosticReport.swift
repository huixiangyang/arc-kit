import ArcKitFinder
import ArcKitPlatform
import ArcKitMouse
import ArcKitWindow
import Foundation

/// 用户主动导出的本地支持报告。只保留运行状态和配置数量，禁止复制文件名、目录、完整设置或日志正文。
public struct SupportDiagnosticReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 4
    public static var privacyNotice: String { L10n.string(.Diagnostics.reportIncludesVersionPermissionsRuntimeStatus) }

    public var schemaVersion: Int
    public var productBundleIdentifier: String
    public var generatedAt: Date
    public var application: SupportDiagnosticApplicationSummary
    public var system: SupportDiagnosticSystemSummary
    public var settings: SupportDiagnosticSettingsSummary
    public var mainRuntime: SupportDiagnosticMainRuntimeSummary?
    public var finderExtensionRuntime: SupportDiagnosticFinderExtensionSummary?
    public var finderCommandRuntime: SupportDiagnosticFinderCommandSummary?
    public var collectionWarnings: [SupportDiagnosticSource]
    public var privacyNotice: String
}

public enum SupportDiagnosticSource: String, Codable, CaseIterable, Equatable, Sendable {
    case mainRuntime
    case finderExtensionRuntime
    case finderCommandRuntime
}

public struct SupportDiagnosticApplicationSummary: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    public var architecture: String
    public var bundleLocation: String
}

public struct SupportDiagnosticSystemSummary: Codable, Equatable, Sendable {
    public var operatingSystemVersion: String
    public var launchAtLoginStatus: String
}

public struct SupportDiagnosticSettingsSummary: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var appearance: String
    public var reduceMotionEnabled: Bool
    public var showDockIcon: Bool
    public var launchAtLoginEnabled: Bool
    public var mouseEnabled: Bool
    public var mouseScrollScope: MouseScrollScope
    public var mouseAppProfileCount: Int
    public var mouseEnabledAppProfileCount: Int
    public var mouseGestureEnabled: Bool
    public var windowEnabled: Bool
    public var windowHotKeysEnabled: Bool
    public var enabledWindowHotKeyCount: Int
    public var windowDragSnapEnabled: Bool
    public var windowExcludedApplicationCount: Int
    public var finderEnabled: Bool
    public var finderEnabledModuleCount: Int
    public var finderTemplateCount: Int
    public var finderFavoriteDirectoryCount: Int
    public var finderFavoriteApplicationCount: Int
    public var finderAdditionalObservedDirectoryCount: Int
}

public struct SupportDiagnosticMainRuntimeSummary: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var processID: Int32
    public var finderExtensionEnabledByUser: Bool
    public var mouseState: ArcKitServiceRuntimeState
    public var mouseAccessibilityTrusted: Bool?
    public var mouseHasWarning: Bool
    public var mouseHasFailure: Bool
    public var windowState: ArcKitServiceRuntimeState
    public var windowAccessibilityTrusted: Bool?
    public var windowAccessibilityOperational: Bool
    public var registeredHotKeyCount: Int
    public var failedHotKeyCount: Int
    public var unsafeHotKeyCount: Int
    public var duplicateHotKeyCount: Int
    public var dragSnapState: ArcKitServiceRuntimeState
    public var dragSnapHasFailure: Bool
    public var lastWindowActionSucceeded: Bool?
}

public struct SupportDiagnosticFinderExtensionSummary: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var processID: Int32
    public var event: FinderExtensionRuntimeEvent
    public var snapshotVersion: Int
    public var isMenuCachePrepared: Bool
    public var observedDirectoryCount: Int
    public var lastMenuItemCount: Int?
    public var lastMenuDurationMs: Int?
    public var lastActionKind: FinderCommandKind?
    public var lastActionDispatchStatus: FinderExtensionActionDispatchStatus?
    public var lastActionWasResolved: Bool?
    public var lastActionHasFailure: Bool
}

public struct SupportDiagnosticFinderCommandSummary: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var agentProcessID: Int32
    public var kind: FinderCommandKind
    public var status: FinderCommandExecutionRuntimeStatus
    public var sourcePathCount: Int
    public var createdPathCount: Int
    public var clipboardResultKind: FinderClipboardResultKind?
    public var hasUserMessage: Bool
    public var hasErrorMessage: Bool
}

public struct SupportDiagnosticReportBuilder: Sendable {
    public init() {}

    public func build(
        settings: AppSettings,
        applicationVersion: String,
        applicationBuild: String,
        bundlePath: String,
        launchAtLoginStatus: String,
        mainRuntime: ArcKitMainAppRuntimeState?,
        finderExtensionRuntime: FinderExtensionRuntimeState?,
        finderCommandRuntime: FinderCommandExecutionRuntimeState?,
        collectionWarnings: [SupportDiagnosticSource],
        generatedAt: Date = Date(),
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> SupportDiagnosticReport {
        let finder = settings.finder.menuConfiguration
        let window = settings.windowManagement
        let mouse = settings.mouseEnhancement
        let settingsSummary = SupportDiagnosticSettingsSummary(
            schemaVersion: settings.schemaVersion,
            appearance: settings.appearance.rawValue,
            reduceMotionEnabled: settings.reduceMotionEnabled,
            showDockIcon: settings.showDockIcon,
            launchAtLoginEnabled: settings.launchAtLoginEnabled,
            mouseEnabled: mouse.isEnabled,
            mouseScrollScope: mouse.scrollScope,
            mouseAppProfileCount: mouse.appProfiles.count,
            mouseEnabledAppProfileCount: mouse.enabledAppProfileCount,
            mouseGestureEnabled: mouse.gestureSettings.isEnabled,
            windowEnabled: window.isEnabled,
            windowHotKeysEnabled: window.hotKeysEnabled,
            enabledWindowHotKeyCount: window.bindings.count(where: \.isEnabled),
            windowDragSnapEnabled: window.dragSnapEnabled,
            windowExcludedApplicationCount: window.excludedApplications.count,
            finderEnabled: finder.isEnabled,
            finderEnabledModuleCount: settings.enabledFinderMenuCount,
            finderTemplateCount: finder.fileTemplates.count,
            finderFavoriteDirectoryCount: finder.favoriteDirectories.count,
            finderFavoriteApplicationCount: finder.favoriteApplications.count,
            finderAdditionalObservedDirectoryCount: finder.additionalObservedDirectoryPaths.count
        )

        return SupportDiagnosticReport(
            schemaVersion: SupportDiagnosticReport.schemaVersion,
            productBundleIdentifier: ArcKitConstants.appBundleIdentifier,
            generatedAt: generatedAt,
            application: SupportDiagnosticApplicationSummary(
                version: applicationVersion,
                build: applicationBuild,
                architecture: Self.architecture,
                bundleLocation: bundlePath == ArcKitConstants.installedAppPath ? "installed" : "other"
            ),
            system: SupportDiagnosticSystemSummary(
                operatingSystemVersion: operatingSystemVersion,
                launchAtLoginStatus: launchAtLoginStatus
            ),
            settings: settingsSummary,
            mainRuntime: mainRuntime.map(Self.mainRuntimeSummary),
            finderExtensionRuntime: finderExtensionRuntime.map(Self.finderExtensionSummary),
            finderCommandRuntime: finderCommandRuntime.map(Self.finderCommandSummary),
            collectionWarnings: SupportDiagnosticSource.allCases.filter(collectionWarnings.contains),
            privacyNotice: SupportDiagnosticReport.privacyNotice
        )
    }

    private static func mainRuntimeSummary(_ state: ArcKitMainAppRuntimeState) -> SupportDiagnosticMainRuntimeSummary {
        SupportDiagnosticMainRuntimeSummary(
            generatedAt: state.generatedAt,
            processID: state.processID,
            finderExtensionEnabledByUser: state.finderExtensionEnabledByUser,
            mouseState: state.mouseEnhancement.state,
            mouseAccessibilityTrusted: state.mouseEnhancement.accessibilityTrusted,
            mouseHasWarning: state.mouseEnhancement.lastRuntimeWarning != nil,
            mouseHasFailure: state.mouseEnhancement.lastFailureReason != nil,
            windowState: state.windowManagement.state,
            windowAccessibilityTrusted: state.windowManagement.accessibilityTrusted,
            windowAccessibilityOperational: state.windowManagement.accessibilityOperational,
            registeredHotKeyCount: state.windowManagement.hotKeyRegisteredCount,
            failedHotKeyCount: state.windowManagement.hotKeyFailedCount,
            unsafeHotKeyCount: state.windowManagement.hotKeyUnsafeCount,
            duplicateHotKeyCount: state.windowManagement.hotKeyDuplicateCount,
            dragSnapState: state.windowManagement.dragSnapState,
            dragSnapHasFailure: state.windowManagement.dragSnapFailureMessage != nil,
            lastWindowActionSucceeded: state.windowManagement.lastActionSucceeded
        )
    }

    private static func finderExtensionSummary(_ state: FinderExtensionRuntimeState) -> SupportDiagnosticFinderExtensionSummary {
        SupportDiagnosticFinderExtensionSummary(
            generatedAt: state.generatedAt,
            processID: state.processID,
            event: state.event,
            snapshotVersion: state.snapshotVersion,
            isMenuCachePrepared: state.isMenuCachePrepared,
            observedDirectoryCount: state.observedDirectoryPaths.count,
            lastMenuItemCount: state.lastMenuBuild?.itemCount,
            lastMenuDurationMs: state.lastMenuBuild?.durationMs,
            lastActionKind: state.lastAction?.commandKind,
            lastActionDispatchStatus: state.lastAction?.dispatchStatus,
            lastActionWasResolved: state.lastAction?.wasResolved,
            lastActionHasFailure: state.lastAction?.failureReason != nil
        )
    }

    private static func finderCommandSummary(_ state: FinderCommandExecutionRuntimeState) -> SupportDiagnosticFinderCommandSummary {
        SupportDiagnosticFinderCommandSummary(
            generatedAt: state.generatedAt,
            agentProcessID: state.agentProcessID,
            kind: state.kind,
            status: state.status,
            sourcePathCount: state.sourcePathCount,
            createdPathCount: state.createdPaths.count,
            clipboardResultKind: state.clipboardResultKind,
            hasUserMessage: state.userMessage != nil,
            hasErrorMessage: state.errorMessage != nil
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

public enum SupportDiagnosticReportStore {
    public enum StoreError: Error, LocalizedError {
        case invalidReport

        public var errorDescription: String? { L10n.string(.Diagnostics.reportDiagnosticReportVerificationWritingFailed) }
    }

    public static func save(_ report: SupportDiagnosticReport, to url: URL) throws {
        try validate(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard try decoder.decode(SupportDiagnosticReport.self, from: data) == report else {
            throw StoreError.invalidReport
        }
        try data.write(to: url, options: .atomic)
        guard try load(from: url) == report else {
            throw StoreError.invalidReport
        }
    }

    public static func load(from url: URL) throws -> SupportDiagnosticReport {
        let data = try ArcKitBoundedFileReader.read(from: url, maximumBytes: 1 * 1_024 * 1_024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SupportDiagnosticReport.self, from: data)
        try validate(report)
        return report
    }

    private static func validate(_ report: SupportDiagnosticReport) throws {
        guard report.schemaVersion == SupportDiagnosticReport.schemaVersion,
              report.productBundleIdentifier == ArcKitConstants.appBundleIdentifier,
              report.privacyNotice == SupportDiagnosticReport.privacyNotice,
              Set(report.collectionWarnings).count == report.collectionWarnings.count
        else {
            throw StoreError.invalidReport
        }
    }
}
