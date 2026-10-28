import ArcKitPlatform
import Carbon.HIToolbox
import Foundation

public enum MenuBarShortcutPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled, controlOptionM, controlOptionShiftM, controlOptionCommandM
    public var id: Self { self }
    var title: String {
        switch self {
        case .disabled: L10n.string(.Common.off)
        case .controlOptionM: "⌃⌥M"
        case .controlOptionShiftM: "⌃⌥⇧M"
        case .controlOptionCommandM: "⌃⌥⌘M"
        }
    }
    var modifiers: UInt32 {
        let base = UInt32(controlKey | optionKey)
        switch self {
        case .disabled: return 0
        case .controlOptionM: return base
        case .controlOptionShiftM: return base | UInt32(shiftKey)
        case .controlOptionCommandM: return base | UInt32(cmdKey)
        }
    }
}

enum MenuBarHotKeyAction: String, Hashable { case shelf, reveal }

@MainActor
protocol MenuBarHotKeyDriving: AnyObject {
    func apply(shelf: MenuBarShortcutPreset, reveal: MenuBarShortcutPreset, action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32]
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

    func apply(shelf: MenuBarShortcutPreset, reveal: MenuBarShortcutPreset, action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32] {
        stop()
        let bindings: [(MenuBarHotKeyAction, MenuBarShortcutPreset)] = [(.shelf, shelf), (.reveal, reveal)].filter { $0.1 != .disabled }
        guard !bindings.isEmpty else { return [:] }
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
            let status = RegisterEventHotKey(46, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: identifier),
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
