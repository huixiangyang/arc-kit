import ArcKitPlatform
import ArcKitWindow
import Combine
import Foundation

/// Runtime Host 拖拽吸附状态在主 App 中的只读投影。
@MainActor
public final class WindowDragSnapService: ObservableObject {
    public enum State: Equatable {
        case stopped
        case waitingForAccessibility
        case running
        case failed(String)
    }

    private let bridge: WindowRuntimeClient
    private var cancellable: AnyCancellable?

    public init(bridge: WindowRuntimeClient) {
        self.bridge = bridge
        cancellable = bridge.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    public var state: State {
        switch bridge.snapshot.dragSnapState {
        case .stopped: .stopped
        case .waitingForAccessibility: .waitingForAccessibility
        case .running: .running
        case .failed: .failed(bridge.snapshot.dragSnapFailureMessage ?? L10n.string(.WindowSettings.snappingUnavailable))
        }
    }

    public var lastFailureMessage: String? { bridge.snapshot.dragSnapFailureMessage }

}
