@testable import ArcKitApplication
import ApplicationServices
import Foundation
import Testing

@Suite("菜单栏取用会话", .serialized)
@MainActor
struct MenuBarShelfTests {
    @Test("管理页直接读取与点按，关闭收纳不受影响，已发送和超时请求不重复执行")
    func managementWorkspace() async throws {
        let fixture = ManualLookupFixture()
        let panel = ManualShelfPanel()
        var drivers = 0
        let service = MenuBarManagementService(driverFactory: { drivers += 1; return ManualPartitionDriver() },
            captureInventory: { try await fixture.capture($0) }, accessSessionFactory: { fixture.session() },
            currentDisplayID: { 9 }, shelfPanelFactory: { _, _ in panel },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        service.apply(.defaults)
        defer { service.stop() }
        let owner = UUID()
        service.beginManagement(owner: owner)
        await service.finishItemRequest()
        #expect(service.managementModel.items.count == 1 && panel.shows == 0 && drivers == 0)
        #expect(service.managementModel.selectedID == nil)
        service.managementModel.query = "ＦＩＸ"
        #expect(service.managementModel.filteredItems.count == 1 && service.managementModel.selectedID == fixture.item.id)
        service.activateManagementItem(fixture.item.id, owner: owner)
        service.activateManagementItem(fixture.item.id, owner: owner)
        await service.finishItemRequest()
        #expect(fixture.actions == 1 && service.managementModel.items.count == 1)
        if case .sent? = service.managementModel.outcomes[fixture.item.id] {} else { Issue.record("Expected sent feedback") }
        service.activateManagementItem(fixture.item.id, owner: owner)
        await service.finishItemRequest()
        #expect(fixture.actions == 1)

        service.endManagement(owner: owner)
        let nextOwner = UUID()
        service.beginManagement(owner: nextOwner)
        await service.finishItemRequest()
        service.activateManagementItem(fixture.item.id, owner: owner)
        #expect(fixture.actions == 1) // 同一个图标 ID 也不能让离开的页面使用新会话。
        fixture.actionResult = AXError.cannotComplete.rawValue
        service.activateManagementItem(fixture.item.id, owner: nextOwner)
        await service.finishItemRequest()
        #expect(fixture.actions == 2 && service.managementModel.staleReason != nil && panel.shows == 0)
        if case .unconfirmed? = service.managementModel.outcomes[fixture.item.id] {} else { Issue.record("Expected unconfirmed feedback") }
        service.activateManagementItem(fixture.item.id, owner: nextOwner)
        #expect(fixture.actions == 2)

        service.refreshManagement(owner: nextOwner)
        await service.finishItemRequest()
        fixture.trusted = false
        service.activateManagementItem(fixture.item.id, owner: nextOwner)
        await service.finishItemRequest()
        #expect(service.managementModel.permissionRequired && service.managementModel.items.isEmpty)
        #expect(fixture.actions == 2 && drivers == 0 && panel.shows == 0)
    }

    @Test("已收起时点按全图标只发送目标动作，不展开整条菜单栏")
    func activationPreservesCollection() async throws {
        let fixture = ManualLookupFixture()
        let driver = ManualPartitionDriver()
        let service = MenuBarManagementService(driverFactory: { driver },
            captureInventory: { try await fixture.capture($0) }, accessSessionFactory: { fixture.session() },
            currentDisplayID: { 9 }, workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        service.present(.collapsed); await service.finishPresentation()
        let owner = UUID()
        service.beginManagement(owner: owner); await service.finishItemRequest()
        service.activateManagementItem(fixture.item.id, owner: owner); await service.finishItemRequest()
        #expect(fixture.actions == 1 && service.requestedPresentation == .collapsed && driver.reveals == 0)
    }

    @Test("页面迟到清单不覆盖快捷面板，旧页面退出不关闭新入口，环境变化让清单失效")
    func managementOwnership() async throws {
        let fixture = ManualLookupFixture()
        let panel = ManualShelfPanel()
        var holdFirst = true
        var resume: CheckedContinuation<Void, Never>?
        var oldAccess: MenuBarItemAccessSession?
        var oldInventory: UUID?
        var oldFinished = false
        let service = MenuBarManagementService(captureInventory: { access in
            let delayed = holdFirst
            if delayed {
                holdFirst = false; oldAccess = access
                await withCheckedContinuation { resume = $0 }
            }
            let result = try await fixture.capture(access)
            if delayed { oldInventory = result.id; oldFinished = true }
            return result
        }, accessSessionFactory: { fixture.session() }, currentDisplayID: { 9 }, shelfPanelFactory: { _, _ in panel },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        service.apply(.defaults)
        defer { service.stop() }
        let owner = UUID()
        service.beginManagement(owner: owner)
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let continuation = try #require(resume)
        service.toggleShelf(scope: .all)
        await service.finishItemRequest()
        let panelInventory = try #require(service.shelfModel.inventoryID)
        service.endManagement(owner: owner)
        #expect(panel.isVisible)
        continuation.resume()
        for _ in 0..<100 where !oldFinished { await Task.yield() }
        await Task.yield()
        #expect(service.shelfModel.inventoryID == panelInventory && panel.isVisible)
        let staleAccess = try #require(oldAccess), staleInventory = try #require(oldInventory)
        #expect(throws: MenuBarItemAccessError.staleSession) {
            try staleAccess.activate(itemID: fixture.item.id, inventoryID: staleInventory, displayID: 9)
        }
        let nextOwner = UUID()
        service.beginManagement(owner: nextOwner)
        await service.finishItemRequest()
        #expect(!panel.isVisible && service.managementModel.inventoryID != nil)
        service.environmentDidChange(.layout)
        #expect(service.managementModel.inventoryID == nil && service.managementModel.staleReason != nil)
        service.activateManagementItem(fixture.item.id, owner: nextOwner)
        #expect(fixture.actions == 0)
        service.stop()
        service.refreshManagement(owner: nextOwner)
        #expect(service.managementModel.inventoryID == nil)
    }

    @Test("关闭收纳仍可搜索和取用图标，不创建分隔线；停止后旧入口不可重开")
    func independentManualSearch() async throws {
        let fixture = ManualLookupFixture()
        let panel = ManualShelfPanel()
        var drivers = 0
        let service = MenuBarManagementService(partitionMode: .offscreen,
            driverFactory: { drivers += 1; return ManualPartitionDriver() },
            captureInventory: { try await fixture.capture($0) }, accessSessionFactory: { fixture.session() },
            shelfPanelFactory: { _, _ in panel },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        service.apply(.defaults)
        defer { service.stop() }
        service.toggleShelf(scope: .collected)
        #expect(panel.shows == 0)
        service.toggleShelf(scope: .all)
        await service.finishItemRequest()
        #expect(panel.isVisible && !service.isEnabled && drivers == 0)
        #expect(!service.shelfModel.supportsCollectedScope && service.shelfModel.filteredItems.count == 1)
        service.shelfModel.activate(fixture.item.id)
        await service.finishItemRequest()
        #expect(fixture.actions == 1 && !panel.isVisible && service.lastActionReceipt != nil)
        service.toggleShelf(scope: .all)
        await service.finishItemRequest()
        service.stop()
        service.toggleShelf(scope: .all)
        #expect(panel.shows == 2 && drivers == 0 && !service.canSearchAllIcons)
    }

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

@MainActor
private final class ManualLookupFixture {
    let display = MenuBarDisplay(id: 9, name: "Fixture", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: nil, scale: 2)
    let item = MenuBarObservedItem(id: UUID(), processID: 900001, processLaunchDate: Date(timeIntervalSince1970: 100),
        bundleIdentifier: "test.manual", applicationName: "Fixture", accessibilityIdentifier: nil, frame: nil, displayID: nil,
        declaresPress: true, declaresShowMenu: false, positionSettable: false)
    var trusted = true
    var actions = 0
    var actionResult: Int32 = 0
    func session() -> MenuBarItemAccessSession {
        MenuBarItemAccessSession(isTrusted: { [self] in trusted }, process: { [self] _ in
            .init(processID: item.processID, launchDate: item.processLaunchDate!, bundleIdentifier: item.bundleIdentifier)
        }, currentDisplays: { [self] in [display] })
    }
    func capture(_ session: MenuBarItemAccessSession) async throws -> MenuBarInventory {
        return populate(session)
    }
    private func populate(_ session: MenuBarItemAccessSession) -> MenuBarInventory {
        let id = UUID()
        session.begin(id: id, displays: [display])
        session.add(.init(item: item, read: { _ in .init(isMenuBarItem: true, actions: [kAXPressAction]) }, perform: { [self] _ in
            actions += 1; return actionResult
        }))
        return .init(id: id, capturedAt: Date(), systemVersion: "Fixture", accessibility: .granted, displays: [display], items: [item], issues: [])
    }
}

@MainActor
private final class ManualShelfPanel: MenuBarShelfPresenting {
    var onDismiss: (() -> Void)?
    var isVisible = false
    var shows = 0
    func show() throws -> UInt32 { shows += 1; isVisible = true; return 9 }
    func close() { isVisible = false }
}

@MainActor
private final class ManualPartitionDriver: MenuBarPartitionDriving {
    var reveals = 0
    func install(deepSectionEnabled: Bool) {}
    func present(_ state: MenuBarPresentation) async throws {}
    func remove() {}
    func refreshLabels() {}
    func revealAll() { reveals += 1 }
    func confirmRevealedLayout() async throws {}
    func layoutSnapshot() throws -> MenuBarPartitionSnapshot { throw MenuBarPartitionError.unavailable }
}
