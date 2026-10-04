import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation

/// 权限必须来自当前会话的有效回包；断线、未连接和未检测都不是“未授权”。
enum PermissionEvidence: Equatable {
    case notRequired, unknown, granted, denied
}

enum HealthAction: Equatable {
    case refresh, accessibility, accessibilitySettings, inputMonitoring, inputMonitoringSettings, automationSettings, extensionSettings, loginItems, repairFinder, settings

    var title: String {
        switch self {
        case .refresh: L10n.string(.Settings.generalCheckAgain)
        case .accessibility: L10n.string(.Overview.healthRequestAccess)
        case .accessibilitySettings, .inputMonitoringSettings, .automationSettings: L10n.string(.Overview.pageManageAccess)
        case .inputMonitoring: L10n.string(.Overview.healthAllowMonitoring)
        case .extensionSettings: L10n.string(.Overview.healthExtensionSettings)
        case .loginItems: L10n.string(.App.applicationBackgroundPermission)
        case .repairFinder: L10n.string(.Overview.healthRepairRegistration)
        case .settings: L10n.string(.Overview.healthViewSettings)
        }
    }
}

struct FeatureHealth: Equatable {
    enum State { case disabled, preview, unknown, blocked, ready, partial }
    var state: State
    var title: String
    var detail: String
    var permission: PermissionEvidence = .unknown
    var action: HealthAction? = nil
    var checkedAt: Date? = nil

    var needsAttention: Bool { state == .blocked || state == .partial }
}

/// 首页、功能页和菜单栏使用同一判定顺序，不在 View 中重新推断权限和健康度。
enum FeatureHealthAssessment {
    private static func inactive(enabled: Bool, preview: Bool) -> FeatureHealth? {
        if preview { return .init(state: .preview, title: L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Overview.healthDebugDisconnected), permission: .unknown) }
        if !enabled { return .init(state: .disabled, title: L10n.string(.Common.off), detail: L10n.string(.Overview.healthEnabledDemand), permission: .notRequired) }
        return nil
    }

    static func permission(lifecycle: RuntimeAgentLifecycleState, processID: Int32,
                           receivedAt: Date?, trusted: Bool, now: Date = Date()) -> PermissionEvidence {
        guard lifecycle != .unavailable, processID > 0, let receivedAt,
              (0...30).contains(now.timeIntervalSince(receivedAt)) else { return .unknown }
        return trusted ? .granted : .denied
    }

    private static func runtime(lifecycle: RuntimeAgentLifecycleState, processID: Int32,
                                receivedAt: Date?, trusted: Bool, failure: String?, now: Date) -> FeatureHealth? {
        if lifecycle == .unavailable || (processID == 0 && lifecycle == .degraded) {
            return .init(state: .blocked, title: L10n.string(.Overview.healthBackgroundServiceDisconnected), detail: failure ?? L10n.string(.Overview.healthPermissionsUnconfirmed), action: .refresh)
        }
        let evidence = permission(lifecycle: lifecycle, processID: processID, receivedAt: receivedAt, trusted: trusted, now: now)
        guard evidence != .unknown else {
            return .init(state: .unknown, title: receivedAt == nil ? L10n.string(.Overview.healthWaitingBackgroundResponse) : L10n.string(.Overview.healthCheckAgainRequired),
                         detail: L10n.string(.Overview.healthCurrentValidResultMissing), action: .refresh, checkedAt: receivedAt)
        }
        if evidence == .denied {
            return .init(state: .blocked, title: L10n.string(.Overview.healthAccessibilityRequired), detail: L10n.string(.Overview.healthGrantAccessArcKitHost),
                         permission: .denied, action: .accessibility, checkedAt: receivedAt)
        }
        if lifecycle != .running {
            return .init(state: .blocked, title: lifecycle == .starting ? L10n.string(.Overview.healthStarting) : L10n.string(.Overview.healthServiceNotReady),
                         detail: failure ?? L10n.string(.Overview.healthServiceUnavailable), permission: .granted,
                         action: .refresh, checkedAt: receivedAt)
        }
        return nil
    }

    static func mouse(settings: MouseEnhancementSettings, snapshot: MouseAgentRuntimeSnapshot,
                      receivedAt: Date?, preview: Bool = false, now: Date = Date()) -> FeatureHealth {
        if let result = inactive(enabled: settings.isEnabled, preview: preview) { return result }
        if let result = runtime(lifecycle: snapshot.lifecycle, processID: snapshot.processID, receivedAt: receivedAt,
                                trusted: snapshot.accessibilityTrusted, failure: snapshot.lastFailureReason, now: now) { return result }
        if settings.scrollScope == .selectedApplications && settings.enabledAppProfileCount == 0 {
            return .init(state: .partial, title: L10n.string(.Overview.healthEligibleAppsMissing), detail: L10n.string(.Overview.healthScopeLimitedSelectedApps),
                         permission: .granted, action: .settings, checkedAt: receivedAt)
        }
        if let warning = snapshot.lastRuntimeWarning {
            return .init(state: .partial, title: L10n.string(.Overview.healthMouseServiceError), detail: warning, permission: .granted,
                         action: .refresh, checkedAt: receivedAt)
        }
        return .init(state: .ready, title: L10n.string(.Overview.healthMonitoring), detail: L10n.string(.Overview.healthMonitoringStartedConfirmScrollingBehaviorUse), permission: .granted, checkedAt: receivedAt)
    }

    static func window(settings: WindowManagementSettings, snapshot: WindowAgentRuntimeSnapshot,
                       receivedAt: Date?, preview: Bool = false, now: Date = Date()) -> FeatureHealth {
        if let result = inactive(enabled: settings.isEnabled, preview: preview) { return result }
        if let result = runtime(lifecycle: snapshot.lifecycle, processID: snapshot.processID, receivedAt: receivedAt,
                                trusted: snapshot.accessibilityTrusted, failure: snapshot.lastResult?.userMessage, now: now) { return result }
        guard snapshot.accessibilityOperational else {
            return .init(state: .blocked, title: L10n.string(.Overview.healthWindowInterfaceUnavailable), detail: L10n.string(.Overview.healthPermissionGrantedWindowInterfaceCheck),
                         permission: .granted, action: .refresh, checkedAt: receivedAt)
        }
        if settings.hotKeysEnabled && (snapshot.hotKeyHandlerInstallationFailed || snapshot.hotKeyRuntimeWarning != nil ||
            !snapshot.hotKeyFailedBindings.isEmpty || !snapshot.hotKeyDuplicateBindings.isEmpty || !snapshot.hotKeyUnsafeBindings.isEmpty ||
            !snapshot.sceneHotKeyFailures.isEmpty ||
            snapshot.hotKeyRegisteredCount < settings.bindings.filter(\.isEnabled).count + settings.scenes.filter({ $0.shortcut?.isEnabled == true }).count) {
            return .init(state: .partial, title: L10n.string(.Overview.healthSomeShortcutsUnavailable), detail: L10n.string(.Overview.healthCheckUnregisteredItemsConflicts),
                         permission: .granted, action: .settings, checkedAt: receivedAt)
        }
        if settings.dragSnapEnabled && snapshot.dragSnapState != .running {
            return .init(state: .partial, title: L10n.string(.Overview.healthSnappingNotReady), detail: snapshot.dragSnapFailureMessage ?? L10n.string(.Overview.healthWindowInterfaceAvailableDragMonitoring),
                         permission: .granted, action: .refresh, checkedAt: receivedAt)
        }
        return .init(state: .ready, title: L10n.string(.Overview.healthServiceReady), detail: L10n.string(.Overview.healthWindowInterfaceEnabledMonitorsPassedChecks), permission: .granted, checkedAt: receivedAt)
    }

    static func finder(enabled: Bool, health: FinderExtensionStatusService.HealthStatus?, preview: Bool = false,
                       refreshing: Bool = false, now: Date = Date()) -> FeatureHealth {
        if let result = inactive(enabled: enabled, preview: preview) { return result }
        guard let health else {
            return .init(state: .unknown, title: refreshing ? L10n.string(.Overview.healthChecking) : L10n.string(.App.menuBarUnchecked), detail: L10n.string(.Overview.healthFinderDiagnosticResultsYetMissing), action: .refresh)
        }
        guard (0...30).contains(now.timeIntervalSince(health.checkedAt)) else {
            return .init(state: .unknown, title: L10n.string(.Overview.healthCheckAgainRequired), detail: L10n.string(.Overview.healthLastCheckExpired), action: .refresh, checkedAt: health.checkedAt)
        }
        var result = finderResult(health)
        result.checkedAt = health.checkedAt
        result.permission = health.extensionFileExists ? (health.extensionEnabledByUser ? .granted : .denied) : .unknown
        return result
    }

    private static func finderResult(_ health: FinderExtensionStatusService.HealthStatus) -> FeatureHealth {
        if !health.extensionFileExists || !health.agentFileExists || !health.launchAgentPlistExists || !health.launchAgentSecureServiceConfigured {
            return .init(state: .blocked, title: L10n.string(.Overview.healthIncompleteInstallation), detail: L10n.string(.Overview.healthRuntimeComponentsMissingDamagedReinstall))
        }
        if !health.extensionEnabledByUser {
            return .init(state: .blocked, title: L10n.string(.Overview.healthExtensionOff), detail: L10n.string(.Overview.healthEnableArcKitMacosExtensionSettings), action: .extensionSettings)
        }
        if !health.plugInKitOnlyCurrentPath {
            return .init(state: .blocked, title: L10n.string(.Overview.healthExtensionRegistrationIssue), detail: L10n.string(.Overview.healthRegistrationPathMissingPoints), action: .repairFinder)
        }
        if !health.launchAgentLoaded {
            if health.launchAgentRequiresApproval {
                return .init(state: .blocked, title: L10n.string(.Runtime.permissionsBackgroundDenied), detail: L10n.string(.Overview.healthCheckBackgroundPermissionMacosLoginItems), action: .loginItems)
            }
            return .init(state: .blocked, title: L10n.string(.Overview.healthBackgroundRegistrationNotReady), detail: L10n.string(.Overview.healthCheckAgainRetryRegistrationIf), action: .refresh)
        }
        if health.agentRunning && !health.agentOnlyCurrentProcess {
            return .init(state: .blocked, title: L10n.string(.Overview.healthBackgroundInstanceIssue), detail: L10n.string(.Overview.healthDuplicateInstallationHint), action: .refresh)
        }
        if !health.snapshotExists || !health.finderEnabled {
            return .init(state: .blocked, title: L10n.string(.Overview.healthMenuConfigurationNotReady), detail: L10n.string(.Overview.healthEnabledMenuConfigurationDetectedYetMissing), action: .refresh)
        }
        if !health.extensionRuntimeResponded {
            return .init(state: .unknown, title: L10n.string(.Overview.healthWaitingFinder), detail: L10n.string(.Overview.healthOpenIncludedFolderCheckAgain), action: .refresh)
        }
        return .init(state: .ready, title: L10n.string(.Overview.healthConnectionReady), detail: health.agentRunning ? L10n.string(.Overview.healthExtensionRespondedVerifyActualMenusActions) : L10n.string(.Overview.healthExtensionRespondedBackgroundStartsDemand))
    }
}
