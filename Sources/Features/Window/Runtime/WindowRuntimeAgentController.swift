import ArcKitWindow
import ArcKitPlatform
import Combine
import Foundation

/// Window Agent 的组合根；一个进程独占 AX、Carbon 和拖拽 EventTap。
@MainActor
public final class WindowRuntimeAgentController {
    public var stateDidChange: (() -> Void)?
    private let launchID: UUID
    private var generation = 0
    private let windowRuntime = WindowAgentRuntime()
    private let hotKeyRuntime = WindowAgentHotKeyRuntime()
    private let dragSnapRuntime = WindowAgentDragSnapRuntime()
    private var settings: WindowManagementSettings = .defaults
    private var cancellables: Set<AnyCancellable> = []
    private var lastHealthProbeAt = Date.distantPast

    public init(launchID: UUID = UUID()) {
        self.launchID = launchID
        let publish: () -> Void = { [weak self] in
            Task { @MainActor in self?.stateDidChange?() }
        }
        windowRuntime.objectWillChange.sink { _ in publish() }.store(in: &cancellables)
        hotKeyRuntime.objectWillChange.sink { _ in publish() }.store(in: &cancellables)
        dragSnapRuntime.objectWillChange.sink { _ in publish() }.store(in: &cancellables)
    }

    public func start(settings: WindowManagementSettings) async {
        await apply(settings)
    }

    public func handle(_ request: WindowAgentRequest) async -> WindowAgentReply {
        do {
            try request.validate()
            switch request.operation {
            case .performAction:
                guard let action = request.action else {
                    throw RuntimeAgentIPCError.missingPayload
                }
                let result: WindowManagementResult
                if let targetID = request.targetID {
                    result = await windowRuntime.perform(action, capturedTargetID: targetID)
                } else {
                    result = await windowRuntime.perform(action)
                }
                return reply(for: request, result: result)
            case .captureTarget:
                let capture = try await windowRuntime.captureWindowTarget(application: request.captureApplication)
                return WindowAgentReply(requestID: request.requestID, state: snapshot(), targetCapture: capture)
            case .fetchState:
                await refreshPermissionAndHealthIfNeeded()
                return reply(for: request)
            }
        } catch {
            return WindowAgentReply(requestID: request.requestID, errorMessage: error.localizedDescription)
        }
    }

    private func apply(_ settings: WindowManagementSettings) async {
        generation += 1
        let expectedGeneration = generation
        self.settings = settings
        // 异步权限探测期间也不能继续接收上一份配置的热键或拖拽。
        hotKeyRuntime.stop()
        dragSnapRuntime.stop()
        await windowRuntime.start(settings: settings)
        guard expectedGeneration == generation else { return }
        switch windowRuntime.state {
        case .running:
            hotKeyRuntime.start(settings: settings, windowService: windowRuntime)
            dragSnapRuntime.start(settings: settings, windowService: windowRuntime)
        case .waitingForAccessibility:
            hotKeyRuntime.stop()
            dragSnapRuntime.start(settings: settings, windowService: windowRuntime)
        case .stopped, .failed:
            hotKeyRuntime.stop()
            dragSnapRuntime.stop()
        }
    }

    public func refreshPermissionAndHealthIfNeeded(now: Date = Date()) async {
        guard settings.isEnabled else { return }
        let trusted = ProcessPermissions.accessibilityTrusted()
        switch windowRuntime.state {
        case .waitingForAccessibility where trusted,
             .running where !trusted,
             .stopped:
            await apply(settings)
        case .running where now.timeIntervalSince(lastHealthProbeAt) >= 10:
            lastHealthProbeAt = now
            if await !windowRuntime.probeAccessibilityOperational() {
                await apply(settings)
            }
        case .failed where now.timeIntervalSince(lastHealthProbeAt) >= 10:
            lastHealthProbeAt = now
            await apply(settings)
        case .waitingForAccessibility, .running, .failed:
            break
        }
    }

    public func stop() {
        generation += 1
        settings.isEnabled = false
        hotKeyRuntime.stop()
        dragSnapRuntime.stop()
        windowRuntime.stop()
    }

    private func reply(
        for request: WindowAgentRequest,
        result: WindowManagementResult? = nil
    ) -> WindowAgentReply {
        WindowAgentReply(
            requestID: request.requestID,
            state: snapshot(lastResult: result ?? windowRuntime.lastResult),
            result: result
        )
    }

    public func snapshot(lastResult: WindowManagementResult? = nil) -> WindowAgentRuntimeSnapshot {
        let lifecycle: RuntimeAgentLifecycleState = switch windowRuntime.state {
        case .stopped: .stopped
        case .waitingForAccessibility: .waitingForAccessibility
        case .running: .running
        case .failed: .degraded
        }
        let dragState: WindowAgentDragSnapState = switch dragSnapRuntime.state {
        case .stopped: .stopped
        case .waitingForAccessibility: .waitingForAccessibility
        case .running: .running
        case .failed: .failed
        }
        return WindowAgentRuntimeSnapshot(
            lifecycle: lifecycle,
            processID: ProcessInfo.processInfo.processIdentifier,
            launchID: launchID,
            accessibilityTrusted: ProcessPermissions.accessibilityTrusted(),
            accessibilityOperational: windowRuntime.accessibilityOperational,
            hotKeyRegisteredCount: hotKeyRuntime.registeredCount,
            hotKeyFailedBindings: hotKeyRuntime.failedBindings,
            hotKeyDuplicateBindings: hotKeyRuntime.duplicateBindings,
            hotKeyUnsafeBindings: hotKeyRuntime.unsafeBindings,
            hotKeyHandlerInstallationFailed: hotKeyRuntime.handlerInstallationFailed,
            hotKeyRuntimeWarning: hotKeyRuntime.lastRuntimeWarning,
            dragSnapState: dragState,
            dragSnapFailureMessage: dragSnapRuntime.lastFailureMessage,
            lastResult: lastResult,
            configurableApplicationCandidate: windowRuntime.configurableApplicationCandidate()
        )
    }
}
