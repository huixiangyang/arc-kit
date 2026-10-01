import ArcKitMouse
import ArcKitPlatform
import Foundation
import Combine

/// Mouse Agent 的组合根；EventTap、CVDisplayLink 和手势状态不得逃逸到主进程。
@MainActor
public final class MouseRuntimeAgentController {
    public var stateDidChange: (() -> Void)?
    private var observation: AnyCancellable?
    private let launchID: UUID
    private let runtime = MouseAgentRuntime()
    private var settings: MouseEnhancementSettings = .defaults

    public init(launchID: UUID = UUID()) {
        self.launchID = launchID
        observation = runtime.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.stateDidChange?() }
        }
    }

    public func start(settings: MouseEnhancementSettings) {
        apply(settings)
    }

    public func handle(_ request: MouseAgentRequest) -> MouseAgentReply {
        do {
            try request.validate()
            switch request.operation {
            case .fetchState:
                refreshPermissionAndHealth()
                return reply(for: request)
            }
        } catch {
            return MouseAgentReply(requestID: request.requestID, errorMessage: error.localizedDescription)
        }
    }

    public func refreshPermissionAndHealth() {
        let trusted = ProcessPermissions.accessibilityTrusted()
        if settings.isEnabled, trusted, runtime.state != .running {
            apply(settings)
        } else if (!settings.isEnabled || !trusted), runtime.state != .stopped {
            // 已经停稳时不重复清理 EventTap、手势 HUD 和平滑滚动状态。
            runtime.stop()
        }
    }

    public func stop() { settings.isEnabled = false; runtime.stop() }

    private func apply(_ settings: MouseEnhancementSettings) {
        self.settings = settings
        guard !settings.isEnabled || ProcessPermissions.accessibilityTrusted() else {
            runtime.stop()
            return
        }
        runtime.start(settings: settings)
    }

    private func reply(for request: MouseAgentRequest) -> MouseAgentReply {
        MouseAgentReply(requestID: request.requestID, state: snapshot())
    }

    public func snapshot() -> MouseAgentRuntimeSnapshot {
        let trusted = ProcessPermissions.accessibilityTrusted()
        let lifecycle: RuntimeAgentLifecycleState
        if settings.isEnabled, !trusted {
            lifecycle = .waitingForAccessibility
        } else {
            lifecycle = switch runtime.state {
            case .stopped: .stopped
            case .running: .running
            case .failedToCreateEventTap, .disabledByUserInput, .eventTapInvalidated: .degraded
            }
        }
        return MouseAgentRuntimeSnapshot(
            lifecycle: lifecycle,
            processID: ProcessInfo.processInfo.processIdentifier,
            launchID: launchID,
            accessibilityTrusted: trusted,
            lastRuntimeWarning: runtime.lastRuntimeWarning,
            lastFailureReason: runtime.lastFailureReason,
            scrollDiagnostics: runtime.scrollDiagnostics
        )
    }
}
