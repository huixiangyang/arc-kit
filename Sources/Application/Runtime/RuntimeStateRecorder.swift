import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation

/// 运行态诊断文件的采集、去重与落盘，不拥有设置编辑权或服务启停权。
@MainActor
final class RuntimeStateRecorder {
    private let settingsProvider: () -> AppSettings?
    private let mouseService: MouseScrollEnhancementService
    private let windowService: WindowManagementService
    private let hotKeyService: GlobalHotKeyService
    private let dragSnapService: WindowDragSnapService
    private var runtimeStateWorkItem: DispatchWorkItem?
    private var lastWrittenRuntimeState: ArcKitMainAppRuntimeState?

    init(settingsProvider: @escaping () -> AppSettings?, mouseService: MouseScrollEnhancementService,
         windowService: WindowManagementService, hotKeyService: GlobalHotKeyService,
         dragSnapService: WindowDragSnapService) {
        self.settingsProvider = settingsProvider
        self.mouseService = mouseService
        self.windowService = windowService
        self.hotKeyService = hotKeyService
        self.dragSnapService = dragSnapService
    }

    func stop() {
        runtimeStateWorkItem?.cancel()
        runtimeStateWorkItem = nil
    }

    func schedule(reason: String) {
        runtimeStateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.write(reason: reason)
        }
        runtimeStateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    func write(reason: String, force: Bool = false) {
        guard let settings = settingsProvider() else { return }
        let mouseEvidence = FeatureHealthAssessment.permission(lifecycle: mouseService.runtimeSnapshot.lifecycle,
            processID: mouseService.agentProcessID, receivedAt: mouseService.lastResponseAt, trusted: mouseService.accessibilityTrusted)
        let mouseAccessibilityTrusted: Bool? = mouseEvidence == .unknown ? nil : mouseEvidence == .granted
        let windowEvidence = FeatureHealthAssessment.permission(lifecycle: windowService.runtimeSnapshot.lifecycle,
            processID: windowService.agentProcessID, receivedAt: windowService.lastResponseAt, trusted: windowService.accessibilityTrusted)
        let windowAccessibilityTrusted: Bool? = windowEvidence == .unknown ? nil : windowEvidence == .granted
        let state = ArcKitMainAppRuntimeState(
            generatedAt: Date(),
            processID: ProcessInfo.processInfo.processIdentifier,
            executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "",
            bundlePath: Bundle.main.bundleURL.path,
            launchArguments: CommandLine.arguments,
            finderExtensionEnabledByUser: FinderExtensionStatusService.isExtensionEnabledByUser(),
            mouseEnhancement: ArcKitMouseRuntimeState(
                agentProcessID: mouseService.agentProcessID,
                agentLaunchID: mouseService.agentLaunchID,
                isEnabled: settings.mouseEnhancement.isEnabled,
                accessibilityTrusted: mouseAccessibilityTrusted,
                state: mouseRuntimeState(mouseService.state, isEnabled: settings.mouseEnhancement.isEnabled, accessibilityTrusted: mouseAccessibilityTrusted),
                lastRuntimeWarning: mouseService.lastRuntimeWarning,
                lastFailureReason: mouseService.lastFailureReason,
                scrollDiagnostics: mouseService.scrollDiagnostics
            ),
            windowManagement: ArcKitWindowRuntimeState(
                agentProcessID: windowService.agentProcessID,
                agentLaunchID: windowService.agentLaunchID,
                isEnabled: settings.windowManagement.isEnabled,
                hotKeysEnabled: settings.windowManagement.hotKeysEnabled,
                dragSnapEnabled: settings.windowManagement.dragSnapEnabled,
                accessibilityTrusted: windowAccessibilityTrusted,
                accessibilityOperational: windowService.accessibilityOperational,
                state: settings.windowManagement.isEnabled && windowAccessibilityTrusted == nil ? .unavailable : windowRuntimeState(windowService.state),
                hotKeyRegisteredCount: hotKeyService.registeredCount,
                hotKeyFailedCount: hotKeyService.failedBindings.count,
                hotKeyUnsafeCount: hotKeyService.unsafeBindings.count,
                hotKeyDuplicateCount: hotKeyService.duplicateBindings.count,
                hotKeyHandlerInstallationFailed: hotKeyService.handlerInstallationFailed,
                hotKeyRuntimeWarning: hotKeyService.lastRuntimeWarning,
                dragSnapState: dragSnapRuntimeState(dragSnapService.state),
                dragSnapFailureMessage: dragSnapService.lastFailureMessage,
                lastActionSucceeded: windowService.lastResult?.succeeded,
                lastActionMessage: windowService.lastResult?.userMessage
            )
        )
        if !force,
           let lastWrittenRuntimeState,
           state.hasSameRuntimeFacts(as: lastWrittenRuntimeState) {
            return
        }
        do {
            try ArcKitRuntimeStateStore.save(state)
            lastWrittenRuntimeState = state
            ArcKitLog.append("main app runtime state saved reason=\(reason) path=\(ArcKitRuntimeStateStore.stateURL.path)")
        } catch {
            ArcKitLog.append("main app runtime state save failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private func mouseRuntimeState(
        _ state: MouseScrollEnhancementService.State,
        isEnabled: Bool,
        accessibilityTrusted: Bool?
    ) -> ArcKitServiceRuntimeState {
        if isEnabled, accessibilityTrusted == nil { return .unavailable }
        if isEnabled, accessibilityTrusted == false {
            return .waitingForAccessibility
        }
        switch state {
        case .stopped: return .stopped
        case .running: return .running
        case .failedToCreateEventTap: return .failedToCreateEventTap
        case .disabledByUserInput: return .disabledByUserInput
        case .eventTapInvalidated: return .eventTapInvalidated
        }
    }

    private func windowRuntimeState(_ state: WindowManagementService.State) -> ArcKitServiceRuntimeState {
        switch state {
        case .stopped: return .stopped
        case .waitingForAccessibility: return .waitingForAccessibility
        case .running: return .running
        case .failed: return .failed
        }
    }

    private func dragSnapRuntimeState(_ state: WindowDragSnapService.State) -> ArcKitServiceRuntimeState {
        switch state {
        case .stopped: return .stopped
        case .waitingForAccessibility: return .waitingForAccessibility
        case .running: return .running
        case .failed: return .failed
        }
    }

}
