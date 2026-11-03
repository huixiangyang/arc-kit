import ArcKitPlatform
import Carbon.HIToolbox
import Foundation

enum MenuBarHotKeyAction: String, Hashable, CaseIterable {
    case shelf, toggle, reveal
    var requiresCollection: Bool { self != .shelf }
    var title: LocalizedStringResource {
        switch self {
        case .shelf: .MenuBar.shelfOpen
        case .toggle: .MenuBar.hotKeyToggle
        case .reveal: .MenuBar.actionShowAll
        }
    }
    var keyPath: WritableKeyPath<MenuBarSettings, HotKeyChord> {
        switch self {
        case .shelf: \.shelfShortcut
        case .toggle: \.toggleShortcut
        case .reveal: \.revealShortcut
        }
    }
}

@MainActor
protocol MenuBarHotKeyDriving: AnyObject {
    func apply(_ shortcuts: [MenuBarHotKeyAction: HotKeyChord], action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32]
    func stop()
}

/// Carbon 全局快捷键不监听键盘文本；冲突原样报告，不抢占已有快捷键。
@MainActor
final class NativeMenuBarHotKeys: MenuBarHotKeyDriving {
    private static let signature: OSType = 0x414B4D42 // AKMB，与窗口 Host 的注册域区分。
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: MenuBarHotKeyAction] = [:]
    private var nextID: UInt32 = 1
    private var callback: ((MenuBarHotKeyAction) -> Void)?

    func apply(_ shortcuts: [MenuBarHotKeyAction: HotKeyChord], action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32] {
        stop()
        let bindings = MenuBarHotKeyAction.allCases.compactMap { action in shortcuts[action].map { (action, $0) } }.filter { $0.1.isEnabled }
        guard !bindings.isEmpty else { return [:] }
        guard bindings.allSatisfy({ $0.1.isSafeGlobalShortcut }),
              Set(bindings.map { $0.1.shortcutIdentifier }).count == bindings.count else {
            return Dictionary(uniqueKeysWithValues: bindings.map { ($0.0, Int32(paramErr)) })
        }
        callback = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), Self.eventCallback, 1, &type,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { callback = nil; return Dictionary(uniqueKeysWithValues: bindings.map { ($0.0, status) }) }
        var failures: [MenuBarHotKeyAction: Int32] = [:]
        for (target, shortcut) in bindings {
            let identifier = nextID
            nextID &+= 1
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers.carbonValue, EventHotKeyID(signature: Self.signature, id: identifier),
                GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference); actions[identifier] = target }
            else { failures[target] = status == noErr ? Int32(eventInternalErr) : status }
        }
        return failures
    }
    func stop() {
        // 先清动作映射，排队中的旧事件即使晚到也不执行新绑定。
        actions.removeAll(); callback = nil
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    private func handle(_ id: UInt32) { if let target = actions[id] { callback?(target) } }
    private static let eventCallback: EventHandlerUPP = { _, event, pointer in
        guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
            identifier.signature == NativeMenuBarHotKeys.signature else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<NativeMenuBarHotKeys>.fromOpaque(pointer).takeUnretainedValue()
        let id = identifier.id
        Task { @MainActor in owner.handle(id) }
        return noErr
    }
}

private extension HotKeyChord.Modifiers {
    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
