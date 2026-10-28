@testable import ArcKitApplication
import ApplicationServices
import Foundation
import Testing

@Suite("菜单栏取用会话", .serialized)
@MainActor
struct MenuBarShelfTests {
    @Test("刷新、应用重启、权限变化与屏幕变化都在发送动作前拒绝")
    func actionGates() throws {
        let display = Self.display
        let item = Self.item("Example")
        var process: MenuBarProcessIdentity? = .init(processID: item.processID, launchDate: item.processLaunchDate!, bundleIdentifier: item.bundleIdentifier)
        let expected = process
        var granted = true
        var displays = [display]
        var sends = 0
        let session = MenuBarItemAccessSession(isTrusted: { granted }, process: { _ in process }, currentDisplays: { displays })
        let id = UUID()
        func populate(_ observation: UUID) {
            session.begin(id: observation, displays: [display])
            session.add(.init(item: item, read: { _ in .init(isMenuBarItem: true, actions: [kAXPressAction]) }, perform: { _ in sends += 1; return 0 }))
        }
        populate(id)
        granted = false
        #expect(throws: MenuBarItemAccessError.permissionDenied) { try session.activate(itemID: item.id, inventoryID: id, displayID: display.id) }
        granted = true
        process = .init(processID: item.processID, launchDate: Date(timeIntervalSince1970: 999), bundleIdentifier: item.bundleIdentifier)
        #expect(throws: MenuBarItemAccessError.processChanged) { try session.activate(itemID: item.id, inventoryID: id, displayID: display.id) }
        process = expected
        displays = []
        #expect(throws: MenuBarItemAccessError.displayChanged) { try session.activate(itemID: item.id, inventoryID: id, displayID: display.id) }
        displays = [display]
        populate(UUID())
        #expect(throws: MenuBarItemAccessError.staleSession) { try session.activate(itemID: item.id, inventoryID: id, displayID: display.id) }
        #expect(sends == 0)
    }

    @Test("失效对象不执行，按原生引用取用离屏图标，超时不重放")
    func nativeObjectAndSingleUse() throws {
        let display = Self.display
        let item = Self.item("Example", frame: CGRect(x: -1000, y: 4, width: 22, height: 22))
        var validRole = false
        var sent: [String] = []
        let session = MenuBarItemAccessSession(isTrusted: { true }, process: { _ in
            .init(processID: item.processID, launchDate: item.processLaunchDate!, bundleIdentifier: item.bundleIdentifier)
        }, currentDisplays: { [display] })
        let observation = UUID()
        session.begin(id: observation, displays: [display])
        session.add(.init(item: item, read: { _ in .init(isMenuBarItem: validRole, actions: [kAXPressAction, kAXShowMenuAction]) }, perform: {
            sent.append($0); return AXError.cannotComplete.rawValue
        }))
        #expect(throws: MenuBarItemAccessError.itemUnavailable) { try session.activate(itemID: item.id, inventoryID: observation, displayID: display.id) }
        #expect(sent.isEmpty)
        validRole = true
        #expect(throws: MenuBarItemAccessError.requestUnconfirmed(AXError.cannotComplete.rawValue)) { try session.activate(itemID: item.id, inventoryID: observation, displayID: display.id) }
        #expect(throws: MenuBarItemAccessError.alreadyConsumed) { try session.activate(itemID: item.id, inventoryID: observation, displayID: display.id) }
        #expect(sent == [kAXShowMenuAction])
        #expect(MenuBarItemAccessError.requestRejected(AXError.apiDisabled.rawValue).requiresPermission)
        session.begin(id: observation, displays: [display])
        session.add(.init(item: item, read: { _ in .init(isMenuBarItem: true, actions: [kAXPressAction]) }, perform: { _ in AXError.actionUnsupported.rawValue }))
        #expect(throws: MenuBarItemAccessError.requestRejected(AXError.actionUnsupported.rawValue)) { try session.activate(itemID: item.id, inventoryID: observation, displayID: display.id) }
    }

    @Test("搜索和键盘跳过不可操作项，悬停不驱动滚动，刷新清除旧选择")
    func shelfSelection() {
        let a = Self.item("Alpha")
        let disabled = Self.item("Beta", press: false)
        let c = Self.item("Gamma")
        let id = UUID()
        let model = MenuBarShelfModel()
        var requests: [UUID] = []
        model.onActivate = { item, observation in
            #expect(observation == id)
            requests.append(item)
        }
        model.begin(clearQuery: true)
        model.activate()
        model.load(.init(id: id, capturedAt: Date(), systemVersion: "fixture", accessibility: .granted,
            displays: [Self.display], items: [a, disabled, c], issues: []))
        #expect(model.selectedID == a.id)
        model.select(c.id)
        #expect(model.scrollTarget == a.id)
        model.move(by: -1)
        #expect(model.selectedID == a.id)
        model.query = "ＧＡＭＭＡ"
        #expect(model.filteredItems.map(\.id) == [c.id] && model.selectedID == c.id)
        model.activate()
        #expect(requests == [c.id])
        model.query = "no match"
        model.activate()
        #expect(model.selectedID == nil && requests.count == 1)
        model.feedback = "Unconfirmed action"
        model.begin(clearQuery: false)
        #expect(model.feedback != nil)
        model.activate(a.id)
        #expect(model.inventoryID == nil && requests.count == 1)
    }

    private static var display: MenuBarDisplay {
        .init(id: 7, name: "Fixture", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: CGRect(x: 630, y: 0, width: 180, height: 32), scale: 2)
    }
    private static func item(_ name: String, press: Bool = true, frame: CGRect? = nil) -> MenuBarObservedItem {
        .init(id: UUID(), processID: 900001, processLaunchDate: Date(timeIntervalSince1970: 100),
            bundleIdentifier: "test.\(name)", applicationName: name, accessibilityIdentifier: nil,
            frame: frame, displayID: nil, declaresPress: press, declaresShowMenu: false, positionSettable: false)
    }
}
