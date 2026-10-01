import ArcKitPlatform
import ArcKitWindow
import Carbon.HIToolbox
import Combine
import Foundation

@MainActor
protocol GlobalHotKeyRegistering {
    func installEventHandler(owner: WindowAgentHotKeyRuntime) -> EventHandlerRef?
    func removeEventHandler(_ reference: EventHandlerRef)
    func register(binding: WindowHotKeyBinding, identifier: UInt32, signature: OSType) -> EventHotKeyRef?
    func unregister(_ reference: EventHotKeyRef)
}

private struct CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func installEventHandler(owner: WindowAgentHotKeyRuntime) -> EventHandlerRef? {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(owner).toOpaque()
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            WindowAgentHotKeyRuntime.eventCallback,
            1,
            &eventType,
            pointer,
            &reference
        )
        guard status == noErr, let reference else {
            return nil
        }
        return reference
    }

    func removeEventHandler(_ reference: EventHandlerRef) {
        RemoveEventHandler(reference)
    }

    func register(binding: WindowHotKeyBinding, identifier: UInt32, signature: OSType) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return nil
        }
        return reference
    }

    func unregister(_ reference: EventHotKeyRef) {
        UnregisterEventHotKey(reference)
    }
}

@MainActor
public final class WindowAgentHotKeyRuntime: ObservableObject {
    private struct RegistrationConfiguration: Equatable {
        var windowManagementEnabled: Bool
        var hotKeysEnabled: Bool
        var bindings: [WindowHotKeyBinding]

        init(_ settings: WindowManagementSettings) {
            windowManagementEnabled = settings.isEnabled
            hotKeysEnabled = settings.hotKeysEnabled
            bindings = settings.bindings
        }
    }

    private struct Registration {
        var reference: EventHotKeyRef
        var action: WindowLayoutAction
    }

    private let registrar: GlobalHotKeyRegistering
    private let accessibilityTrusted: () -> Bool
    private let registrationRetryDelays: [TimeInterval]
    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1
    private var windowService: WindowAgentRuntime?
    private var activeConfiguration: RegistrationConfiguration?
    private var registrationRetryAttempt = 0
    private var registrationRetryWorkItem: DispatchWorkItem?
    @Published public private(set) var failedBindings: [WindowHotKeyBinding] = []
    @Published public private(set) var duplicateBindings: [WindowHotKeyBinding] = []
    @Published public private(set) var unsafeBindings: [WindowHotKeyBinding] = []
    @Published public private(set) var registeredCount: Int = 0
    @Published public private(set) var handlerInstallationFailed = false
    @Published public private(set) var lastRegistrationError: String?
    @Published public private(set) var lastRuntimeWarning: String?

    public convenience init() {
        self.init(
            registrar: CarbonGlobalHotKeyRegistrar(),
            accessibilityTrusted: ProcessPermissions.accessibilityTrusted
        )
    }

    init(
        registrar: GlobalHotKeyRegistering,
        accessibilityTrusted: @escaping () -> Bool,
        registrationRetryDelays: [TimeInterval] = [0.4, 1.0, 2.0]
    ) {
        self.registrar = registrar
        self.accessibilityTrusted = accessibilityTrusted
        self.registrationRetryDelays = registrationRetryDelays
    }

    public func start(settings: WindowManagementSettings, windowService: WindowAgentRuntime) {
        let configuration = RegistrationConfiguration(settings)
        if activeConfiguration == configuration, !handlerInstallationFailed {
            self.windowService = windowService
            scheduleFailedRegistrationRetryIfNeeded()
            ArcKitLog.append(
                "window hotkey unchanged registered=\(registeredCount) failed=\(failedBindings.count)"
            )
            return
        }
        stop()
        guard settings.isEnabled else {
            ArcKitLog.append("window hotkey skipped reason=window-management-disabled")
            return
        }
        guard settings.hotKeysEnabled else {
            ArcKitLog.append("window hotkey skipped reason=hotkeys-disabled")
            return
        }
        guard accessibilityTrusted() else {
            ArcKitLog.append("window hotkey skipped reason=accessibility-not-trusted")
            return
        }
        lastRuntimeWarning = nil
        activeConfiguration = configuration
        self.windowService = windowService
        let plan = settings.hotKeyRegistrationPlan()
        unsafeBindings = plan.unsafeBindings
        duplicateBindings = plan.duplicateBindings
        for binding in unsafeBindings {
            ArcKitLog.append("window hotkey unsafe skipped action=\(binding.action.rawValue) shortcut=\(binding.displayShortcut)")
        }
        for binding in duplicateBindings {
            ArcKitLog.append("window hotkey duplicate action=\(binding.action.rawValue) shortcut=\(binding.displayShortcut)")
        }
        guard plan.validBindings.isEmpty || installEventHandlerIfNeeded() else {
            handlerInstallationFailed = true
            lastRegistrationError = L10n.string(.WindowRuntime.shortcutsEventHandlerFailed)
            failedBindings = plan.validBindings
            registeredCount = 0
            ArcKitLog.append("window hotkey handler install failed validBindings=\(plan.validBindings.count)")
            return
        }
        for binding in plan.validBindings {
            if !register(binding) {
                failedBindings.append(binding)
                ArcKitLog.append("window hotkey register failed action=\(binding.action.rawValue) shortcut=\(binding.displayShortcut)")
            }
        }
        registeredCount = registrations.count
        lastRegistrationError = failedBindings.isEmpty
            ? nil
            : L10n.string(.WindowRuntime.shortcutsRetryingRegistration(String(describing: failedBindings.count)))
        ArcKitLog.append("window hotkey started registered=\(registeredCount) failed=\(failedBindings.count) unsafe=\(unsafeBindings.count) duplicates=\(duplicateBindings.count)")
        scheduleFailedRegistrationRetryIfNeeded()
    }

    private var configurationGeneration = 0

    public func stop() {
        configurationGeneration += 1
        registrationRetryWorkItem?.cancel()
        registrationRetryWorkItem = nil
        registrationRetryAttempt = 0
        for registration in registrations.values {
            registrar.unregister(registration.reference)
        }
        registrations.removeAll()
        failedBindings = []
        duplicateBindings = []
        unsafeBindings = []
        registeredCount = 0
        handlerInstallationFailed = false
        lastRegistrationError = nil
        lastRuntimeWarning = nil
        if let eventHandler {
            registrar.removeEventHandler(eventHandler)
            self.eventHandler = nil
        }
        windowService = nil
        activeConfiguration = nil
    }

    private func scheduleFailedRegistrationRetryIfNeeded() {
        guard !failedBindings.isEmpty,
              registrationRetryAttempt < registrationRetryDelays.count,
              windowService != nil
        else { return }
        registrationRetryWorkItem?.cancel()
        let delay = registrationRetryDelays[registrationRetryAttempt]
        registrationRetryAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.retryFailedRegistrations()
            }
        }
        registrationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        ArcKitLog.append(
            "window hotkey retry scheduled attempt=\(registrationRetryAttempt) delay=\(delay) failed=\(failedBindings.count)"
        )
    }

    private func retryFailedRegistrations() {
        registrationRetryWorkItem = nil
        guard accessibilityTrusted(), windowService != nil, !failedBindings.isEmpty else { return }
        let pending = failedBindings
        failedBindings = []
        for binding in pending where !register(binding) {
            failedBindings.append(binding)
        }
        registeredCount = registrations.count
        lastRegistrationError = failedBindings.isEmpty
            ? nil
            : L10n.string(.WindowRuntime.shortcutsRetryingRegistration(String(describing: failedBindings.count)))
        ArcKitLog.append(
            "window hotkey retry finished attempt=\(registrationRetryAttempt) registered=\(registeredCount) failed=\(failedBindings.count)"
        )
        scheduleFailedRegistrationRetryIfNeeded()
    }

    func handle(identifier: UInt32) {
        guard let action = registrations[identifier]?.action else {
            lastRuntimeWarning = L10n.string(.WindowRuntime.shortcutsUnregisteredEvent)
            ArcKitLog.append("window hotkey stale event id=\(identifier) registered=\(registrations.count)")
            return
        }
        guard let windowService else {
            lastRuntimeWarning = L10n.string(.WindowRuntime.shortcutsServiceUnavailable)
            ArcKitLog.append("window hotkey missing window service id=\(identifier) action=\(action.rawValue)")
            return
        }
        ArcKitLog.append("window hotkey pressed id=\(identifier) action=\(action.rawValue)")
        let generation = configurationGeneration
        Task { [weak self] in
            guard self?.configurationGeneration == generation else { return }
            _ = await windowService.perform(action)
        }
    }

    @discardableResult
    private func register(_ binding: WindowHotKeyBinding) -> Bool {
        guard let reference = registrar.register(binding: binding, identifier: nextIdentifier, signature: Self.signature) else {
            return false
        }
        registrations[nextIdentifier] = Registration(reference: reference, action: binding.action)
        nextIdentifier += 1
        return true
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        guard let reference = registrar.installEventHandler(owner: self) else {
            return false
        }
        eventHandler = reference
        return true
    }

    private static let signature: OSType = {
        let bytes = Array("ArKw".utf8)
        return bytes.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    fileprivate static let eventCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return noErr
        }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == WindowAgentHotKeyRuntime.signature else {
            return noErr
        }
        let service = Unmanaged<WindowAgentHotKeyRuntime>.fromOpaque(userData).takeUnretainedValue()
        let identifier = hotKeyID.id
        DispatchQueue.main.async {
            Task { @MainActor in
                service.handle(identifier: identifier)
            }
        }
        return noErr
    }
}

private extension WindowHotKeyModifier {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
