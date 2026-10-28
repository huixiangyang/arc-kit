import ArcKitPlatform
import AppKit
import ApplicationServices

struct MenuBarProcessIdentity: Equatable {
    let processID: Int32
    let launchDate: Date
    let bundleIdentifier: String?
}

struct MenuBarItemActionState {
    var frame: CGRect? = nil
    let isMenuBarItem: Bool
    let actions: Set<String>
}

/// 内存中的原生对象引用，不能编码到配置或以坐标重建。
@MainActor
struct MenuBarItemTarget {
    let item: MenuBarObservedItem
    let read: (_ includeFrame: Bool) throws -> MenuBarItemActionState
    let perform: (String) -> Int32
}

enum MenuBarItemAccessError: Error, LocalizedError, Equatable {
    case staleSession, permissionDenied, processChanged, displayChanged, itemUnavailable, unsupportedAction, alreadyConsumed, sectionChanged
    case requestUnconfirmed(Int32), requestRejected(Int32)
    var requiresPermission: Bool {
        if self == .permissionDenied { return true }
        if case let .requestRejected(code) = self { return code == AXError.apiDisabled.rawValue }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .staleSession, .alreadyConsumed: L10n.string(.MenuBar.accessStale)
        case .permissionDenied: L10n.string(.MenuBar.settingsMainPermission)
        case .sectionChanged: L10n.string(.MenuBar.scopeChanged)
        case .processChanged: L10n.string(.MenuBar.accessProcessChanged)
        case .displayChanged: L10n.string(.MenuBar.accessDisplayChanged)
        case .itemUnavailable: L10n.string(.MenuBar.accessItemUnavailable)
        case .unsupportedAction: L10n.string(.MenuBar.accessUnsupported)
        case let .requestRejected(code): L10n.string(.MenuBar.accessRejected(String(code)))
        case let .requestUnconfirmed(code): L10n.string(.MenuBar.accessUnconfirmed(String(code)))
        }
    }
}

/// 一个发现快照对应一组动作令牌。刷新、关闭、停用会释放全部引用。
@MainActor
final class MenuBarItemAccessSession {
    private var inventoryID: UUID?
    private var displays: [MenuBarDisplay] = []
    private var targets: [UUID: MenuBarItemTarget] = [:]
    private var consumed: Set<UUID> = []
    private let isTrusted: () -> Bool
    private let process: (Int32) -> MenuBarProcessIdentity?
    private let currentDisplays: () -> [MenuBarDisplay]

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         process: @escaping (Int32) -> MenuBarProcessIdentity? = { pid in
             guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let date = app.launchDate else { return nil }
             return .init(processID: pid, launchDate: date, bundleIdentifier: app.bundleIdentifier)
         }, currentDisplays: @escaping () -> [MenuBarDisplay] = { MenuBarScreenSnapshot.capture()?.displays ?? [] }) {
        self.isTrusted = isTrusted; self.process = process; self.currentDisplays = currentDisplays
    }

    func begin(id: UUID, displays: [MenuBarDisplay]) {
        invalidate()
        inventoryID = id
        self.displays = displays
    }
    func add(_ target: MenuBarItemTarget) { targets[target.item.id] = target }
    func invalidate() { inventoryID = nil; targets.removeAll(); consumed.removeAll(); displays.removeAll() }

    /// success 仅表示 AX 接受一次请求，不代表原生菜单已经显示。失败或超时也不自动重试。
    func activate(itemID: UUID, inventoryID: UUID, displayID: UInt32, collection: MenuBarCollectionConstraint? = nil) throws {
        guard self.inventoryID == inventoryID, let target = targets[itemID] else { throw MenuBarItemAccessError.staleSession }
        guard !consumed.contains(itemID) else { throw MenuBarItemAccessError.alreadyConsumed }
        guard isTrusted() else { throw MenuBarItemAccessError.permissionDenied }
        let item = target.item
        guard let launch = item.processLaunchDate,
              item.processID != ProcessInfo.processInfo.processIdentifier,
              process(item.processID) == .init(processID: item.processID, launchDate: launch, bundleIdentifier: item.bundleIdentifier) else {
            throw MenuBarItemAccessError.processChanged
        }
        guard !displays.isEmpty, currentDisplays() == displays,
              displays.contains(where: { $0.id == displayID }) else { throw MenuBarItemAccessError.displayChanged }
        let state = try target.read(collection != nil)
        // AX 动作直接作用于对象；隐藏/刘海位置不是坐标点击前提，不因图标离屏而改选其他对象。
        guard state.isMenuBarItem else { throw MenuBarItemAccessError.itemUnavailable }
        if let collection {
            guard collection.snapshot.displays == displays, collection.snapshot.displayID == displayID,
                  collection.snapshot.section(frame: state.frame) == .collected, collection.isCurrent() else {
                throw MenuBarItemAccessError.sectionChanged
            }
        }
        let action: String
        if state.actions.contains(kAXShowMenuAction) { action = kAXShowMenuAction }
        else if state.actions.contains(kAXPressAction) { action = kAXPressAction }
        else { throw MenuBarItemAccessError.unsupportedAction }
        // 在发送前消费，IPC 超时也不能让双击或 Enter 重复执行具有副作用的状态项。
        consumed.insert(itemID)
        let result = target.perform(action)
        guard result != AXError.success.rawValue else { return }
        if [AXError.actionUnsupported.rawValue, AXError.invalidUIElement.rawValue, AXError.illegalArgument.rawValue, AXError.apiDisabled.rawValue].contains(result) {
            throw MenuBarItemAccessError.requestRejected(result)
        }
        throw MenuBarItemAccessError.requestUnconfirmed(result)
    }
}

extension MenuBarItemTarget {
    static func native(item: MenuBarObservedItem, element: AXUIElement) -> Self {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return .init(item: item, read: { includeFrame in
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
                throw MenuBarItemAccessError.itemUnavailable
            }
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success else { throw MenuBarItemAccessError.unsupportedAction }
            return .init(frame: includeFrame ? MenuBarInspector.frame(element) : nil, isMenuBarItem: (role as? String) == kAXMenuBarItemRole, actions: Set(names as? [String] ?? []))
        }, perform: { AXUIElementPerformAction(element, $0 as CFString).rawValue })
    }
}
