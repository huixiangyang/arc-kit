import ArcKitPlatform
import ArcKitWindow
import Combine
import Foundation

/// Runtime Host 快捷键状态在主 App 中的只读投影。
@MainActor
public final class GlobalHotKeyService: ObservableObject {
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

    public var failedBindings: [WindowHotKeyBinding] { bridge.snapshot.hotKeyFailedBindings }
    public var duplicateBindings: [WindowHotKeyBinding] { bridge.snapshot.hotKeyDuplicateBindings }
    public var unsafeBindings: [WindowHotKeyBinding] { bridge.snapshot.hotKeyUnsafeBindings }
    public var registeredCount: Int { bridge.snapshot.hotKeyRegisteredCount }
    public var handlerInstallationFailed: Bool { bridge.snapshot.hotKeyHandlerInstallationFailed }
    public var lastRegistrationError: String? {
        failedBindings.isEmpty ? nil : L10n.string(.WindowSettings.shortcutsFailedCount(Int(failedBindings.count)))
    }
    public var lastRuntimeWarning: String? { bridge.snapshot.hotKeyRuntimeWarning }

}
