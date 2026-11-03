import ArcKitPlatform
import AppKit
import Carbon

/// 输入法菜单由系统代理持有，不在普通应用的 allowed 注册表里。
/// 只改它的显示开关，不变更输入源、快捷键，也不重启输入法或系统代理。
struct MenuBarInputMenu {
    static let bundleIdentifier = "com.apple.TextInputMenuAgent"
    static let itemIdentifier = "Item-0"
    private let domain: CFString
    private let key = "visible" as CFString

    init(domain: String = "com.apple.TextInputMenu") { self.domain = domain as CFString }

    func isVisible() throws -> Bool {
        guard CFPreferencesAppSynchronize(domain),
              let value = CFPreferencesCopyAppValue(key, domain) as? Bool else {
            throw MenuBarVisibilityError.inputMenuUnavailable
        }
        return value
    }

    func setVisible(_ visible: Bool) throws {
        CFPreferencesSetAppValue(key, visible ? kCFBooleanTrue : kCFBooleanFalse, domain)
        guard CFPreferencesAppSynchronize(domain), try isVisible() == visible else {
            throw MenuBarVisibilityError.unconfirmed
        }
    }

    @MainActor static var displayName: String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return L10n.string(.MenuBar.inputMenuTitle)
        }
        let name = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return L10n.string(.MenuBar.inputMenuNamed(name))
    }

    /// 隐藏后系统会撤掉 AX 项；编排页从自己的恢复清单保留该设置项，仍可移回常驻。
    /// 不把此设置记录加入原生动作会话，避免把持久化目标冒充可点击的 AX 对象。
    @MainActor static func addingManagedItem(to inventory: MenuBarInventory) throws -> MenuBarInventory {
        guard inventory.accessibility == .granted,
              !inventory.items.contains(where: { $0.bundleIdentifier == bundleIdentifier }),
              try MenuBarVisibilityRecovery().read()?.bundles.contains(bundleIdentifier) == true else { return inventory }
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated }
        let item = MenuBarObservedItem(id: UUID(), processID: app?.processIdentifier ?? 0,
            processLaunchDate: app.flatMap { MenuBarProcessIdentity.capture($0)?.launchDate },
            bundleIdentifier: bundleIdentifier, applicationName: displayName, accessibilityIdentifier: itemIdentifier,
            frame: nil, displayID: nil, declaresPress: false, declaresShowMenu: false, positionSettable: false)
        return .init(id: inventory.id, capturedAt: inventory.capturedAt, systemVersion: inventory.systemVersion,
            accessibility: inventory.accessibility, displays: inventory.displays, items: inventory.items + [item], issues: inventory.issues)
    }
}
