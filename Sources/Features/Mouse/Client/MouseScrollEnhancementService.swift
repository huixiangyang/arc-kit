import ArcKitMouse
import Combine
import Foundation

/// 主 App 的鼠标状态代理。真实 EventTap 与平滑滚动只存在于 ArcKitRuntimeHost。
@MainActor
public final class MouseScrollEnhancementService: ObservableObject {
    public enum State: Equatable {
        case stopped
        case running
        case failedToCreateEventTap
        case disabledByUserInput
        case eventTapInvalidated
    }

    private let bridge: MouseRuntimeClient
    private var cancellable: AnyCancellable?

    public init(bridge: MouseRuntimeClient) {
        self.bridge = bridge
        cancellable = bridge.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    public var state: State {
        switch bridge.snapshot.lifecycle {
        case .running: .running
        case .waitingForAccessibility, .stopped, .starting: .stopped
        case .degraded: .eventTapInvalidated
        case .safeMode, .unavailable: .failedToCreateEventTap
        }
    }

    public var isRunning: Bool { state == .running }
    public var agentProcessID: Int32 { bridge.snapshot.processID }
    public var agentLaunchID: UUID { bridge.snapshot.launchID }
    var runtimeSnapshot: MouseAgentRuntimeSnapshot { bridge.snapshot }
    var lastResponseAt: Date? { bridge.lastResponseAt }

    public var accessibilityTrusted: Bool { bridge.snapshot.accessibilityTrusted }
    public var scrollDiagnostics: MouseScrollDiagnostics { bridge.snapshot.scrollDiagnostics }
    public var lastRuntimeWarning: String? { bridge.snapshot.lastRuntimeWarning }
    public var lastFailureReason: String? { bridge.snapshot.lastFailureReason }

    public func refresh() {
        bridge.refresh()
    }



    public func reportConfigurationFailure(_ message: String) {
        bridge.recordLocalFailure(message)
    }
}
