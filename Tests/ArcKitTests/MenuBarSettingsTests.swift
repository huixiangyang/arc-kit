@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitFinder
import Foundation
import Testing

@Suite("菜单栏配置与生命周期", .serialized)
struct MenuBarSettingsTests {
    @Test("系统溢出使用有界分段，不创建深度区或提供失真的普通区筛选")
    @MainActor func systemOverflowPolicy() throws {
        let displays = [
            MenuBarDisplay(id: 1, name: "Notched", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           topBand: CGRect(x: 0, y: 0, width: 1512, height: 34),
                           notch: CGRect(x: 662, y: 0, width: 188, height: 34), scale: 2),
            MenuBarDisplay(id: 2, name: "Wide", frame: CGRect(x: 0, y: -1440, width: 2560, height: 1440),
                           topBand: CGRect(x: 0, y: -1440, width: 2560, height: 31), notch: nil, scale: 1)
        ]
        let plan = try MenuBarOverflowPlan(displays: displays)
        #expect(plan.segmentLength == 267 && plan.segmentCount == 10)
        #expect(plan.segmentLength * CGFloat(plan.segmentCount) >= 2660)
        #expect(throws: MenuBarPartitionError.self) { try MenuBarOverflowPlan(displays: []) }
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(partitionMode: .systemOverflow, driverFactory: { driver })
        defer { service.stop() }
        service.apply(.init(isEnabled: true, deepSectionEnabled: true))
        #expect(!driver.installedDeepSection && !service.shelfModel.supportsCollectedScope)
        #expect(service.partitionMode.presentations == [.collapsed, .all])
        service.toggleShelf(scope: .collected)
        #expect(service.message != nil)
        service.shelfModel.scope = .collected
        #expect(service.shelfModel.filteredItems.isEmpty && service.shelfModel.scopeError != nil)
        service.shelfModel.scope = .all
        #expect(service.shelfModel.scopeError == nil)
    }

    @Test("旧库只补关闭配置，保存失败保持原事务，备份恢复与严格JSON往返")
    func storageAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var original = try repository.load()
        original.windowManagement.windowGap = 18
        let previous = try repository.save(original)
        try repository.database.write { db in
            try db.execute(sql: "DROP TABLE menu_bar_preferences")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='menu-bar-management-v1'")
        }
        try repository.database.close()
        let beforeShortcuts = SettingsRepository(directoryURL: root)
        let beforeShortcutSnapshot = try beforeShortcuts.loadSnapshot()
        #expect(beforeShortcutSnapshot.settings == original)
        #expect(beforeShortcutSnapshot.revision.runtime == previous.revision.runtime)
        try beforeShortcuts.database.write { db in
            try db.execute(sql: "ALTER TABLE menu_bar_preferences DROP COLUMN shelfShortcut")
            try db.execute(sql: "ALTER TABLE menu_bar_preferences DROP COLUMN revealShortcut")
            try db.execute(sql: "UPDATE menu_bar_preferences SET _types=json_remove(_types, '$.shelfShortcut', '$.revealShortcut')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='menu-bar-shortcuts-v1'")
        }
        try beforeShortcuts.database.close()
        let withShortcuts = SettingsRepository(directoryURL: root)
        #expect(try withShortcuts.load().menuBar.shelfShortcut == .disabled)
        #expect(try withShortcuts.load().menuBar.revealShortcut == .disabled)
        try withShortcuts.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        var changed = original
        changed.menuBar = .init(isEnabled: true, deepSectionEnabled: true, style: .floating, opacity: 0.55, cornerRadius: 12, shelfShortcut: .controlOptionM, revealShortcut: .controlOptionShiftM)
        try upgraded.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_menu_bar BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END")
        }
        #expect(throws: (any Error).self) { try upgraded.save(changed) }
        #expect(try upgraded.loadSnapshot() == migrated)
        try upgraded.database.write { try $0.execute(sql: "DROP TRIGGER reject_menu_bar") }
        let saved = try upgraded.save(changed)
        #expect(saved.revision.runtime == migrated.revision.runtime)
        let backup = try StorageMaintenance(database: upgraded.database).backup(full: true)
        try upgraded.save(original)
        try StorageMaintenance(database: upgraded.database).restore(backup)
        #expect(try upgraded.load() == changed)
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)) == changed)
        var invalid = changed; invalid.menuBar.opacity = 2
        #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        invalid = changed; invalid.menuBar.revealShortcut = invalid.menuBar.shelfShortcut
        #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        invalid = changed; invalid.schemaVersion -= 1
        #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        try upgraded.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        #expect(try reopened.load() == changed)
        try reopened.database.close()
    }

    @Test("仅已提交设置触发控件，失败草稿不生效，停用释放且不会重启Host")
    @MainActor func committedLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("templates")))
        await model.waitForPendingChanges()
        let driver = MenuBarDriverFixture()
        let hotKeys = MenuBarHotKeyFixture()
        let service = MenuBarManagementService(driverFactory: { driver }, hotKeyFactory: { hotKeys })
        let session = RuntimeSettingsSession(model: model) { _, current in service.apply(current.menuBar) }
        session.start()
        defer { session.stop(); service.stop() }
        model.menuBarEditor.update { $0.shelfShortcut = .controlOptionM }
        #expect(await model.finishPendingChanges())
        #expect(hotKeys.applications == 0 && driver.installations == 0)
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_menu_bar BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END")
        }
        model.menuBarEditor.update { $0.isEnabled = true }
        #expect(driver.installations == 0)
        #expect(!(await model.finishPendingChanges()))
        #expect(driver.installations == 0 && !service.isEnabled)
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER reject_menu_bar") }
        #expect(await model.finishPendingChanges())
        #expect(driver.installations == 1 && service.isEnabled)
        #expect(hotKeys.applications == 1 && service.hotKeyFailures[.shelf] == -9878)
        hotKeys.fail = false
        service.retryHotKeys()
        #expect(hotKeys.applications == 2 && service.hotKeyFailures.isEmpty)
        model.menuBarEditor.update { $0.opacity = 0.5 }
        #expect(await model.finishPendingChanges())
        #expect(driver.installations == 1)
        service.present(.collapsed)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed)
        model.menuBarEditor.update { $0.isEnabled = false }
        #expect(await model.finishPendingChanges())
        #expect(driver.removals == 1 && !service.isEnabled && hotKeys.stops == 1)
        try repository.database.close()
    }

    @Test("调试不构造系统控件，退出取消迟到的收起，布局失败恢复全部")
    @MainActor func previewCancellationAndFailure() async {
        let driver = MenuBarDriverFixture()
        var constructions = 0
        let preview = MenuBarManagementService(isPreview: true, driverFactory: { constructions += 1; return driver })
        preview.apply(.init(isEnabled: true, shelfShortcut: .controlOptionM))
        preview.toggleShelf(scope: .all)
        preview.present(.collapsed)
        preview.refreshInventory()
        #expect(constructions == 0 && !preview.isEnabled && !preview.isInspecting)
        let service = MenuBarManagementService(driverFactory: { driver })
        service.apply(.init(isEnabled: true))
        driver.failCollapse = true
        service.present(.collapsed)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .all && service.message != nil)
        driver.failCollapse = false
        driver.delayCollapse = true
        service.present(.collapsed)
        await Task.yield()
        service.stop()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(!service.isEnabled && service.requestedPresentation == .all)
        #expect(driver.lastPresentation == .all && driver.removals == 1)
    }

    @Test("环境变化取消旧收起与清单，只有最新恢复确认能重新开放收纳")
    @MainActor func environmentRecoveryCancelsStaleWork() async throws {
        let driver = MenuBarDriverFixture()
        driver.deferConfirmation = true
        let capture = MenuBarInventoryFixture()
        let service = MenuBarManagementService(driverFactory: { driver }, captureInventory: { try await capture.capture() },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        service.refreshInventory()
        for _ in 0..<100 where capture.requests.isEmpty { await Task.yield() }
        try #require(capture.requests.count == 1)
        driver.delayCollapse = true
        service.present(.collapsed)
        await Task.yield()
        service.environmentDidChange(.layout)
        for _ in 0..<100 where driver.confirmations.isEmpty { await Task.yield() }
        try #require(driver.confirmations.count == 1)
        #expect(service.environmentState == .settling && service.requestedPresentation == .all)
        #expect(service.inventory == nil && !service.isInspecting)

        // 新清单仍可独立发现；旧 AX 捕获即使忽略取消，也不能覆盖新请求或结束其 loading。
        service.refreshInventory()
        for _ in 0..<100 where capture.requests.count < 2 { await Task.yield() }
        try #require(capture.requests.count == 2)
        let stale = capture.requests.removeFirst()
        stale.resume(returning: MenuBarInventoryFixture.inventory())
        await Task.yield()
        #expect(service.inventory == nil && service.isInspecting)
        let current = MenuBarInventoryFixture.inventory()
        capture.requests.removeFirst().resume(returning: current)
        for _ in 0..<100 where service.isInspecting { await Task.yield() }
        #expect(service.inventory?.id == current.id)

        service.environmentDidChange(.layout)
        for _ in 0..<100 where driver.confirmations.count < 2 { await Task.yield() }
        try #require(driver.confirmations.count == 2)
        driver.confirmations.removeFirst().resume(returning: ())
        await Task.yield()
        #expect(service.environmentState == .settling && service.inventory == nil)
        driver.confirmations.removeFirst().resume(returning: ())
        await service.finishEnvironmentRecovery()
        try await Task.sleep(for: .milliseconds(40))
        #expect(service.environmentState == .ready && service.requestedPresentation == .all)
        #expect(driver.lastPresentation == .all && driver.installations == 1)
        driver.delayCollapse = false
        service.present(.collapsed)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed)
    }

    @Test("睡眠屏蔽迟到切屏与收起，恢复失败保持全部，显示全部可重试，停用拒绝迟到确认")
    @MainActor func sleepAndFailedRecovery() async throws {
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(driverFactory: { driver },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        service.apply(.init(isEnabled: true))
        service.environmentDidChange(.sleep)
        service.environmentDidChange(.layout)
        service.present(.collapsed)
        service.present(.all)
        service.refreshInventory()
        #expect(service.environmentState == .sleeping && service.requestedPresentation == .all)
        #expect(driver.confirmationRequests == 0 && !service.isInspecting)
        driver.failConfirmation = true
        service.environmentDidChange(.wake)
        await service.finishEnvironmentRecovery()
        #expect(service.environmentState == .unconfirmed && service.message != nil)
        service.present(.collapsed)
        #expect(service.requestedPresentation == .all && driver.lastPresentation == .all)
        driver.failConfirmation = false
        driver.deferConfirmation = true
        service.apply(.init(isEnabled: true, deepSectionEnabled: true))
        for _ in 0..<100 where driver.confirmations.isEmpty { await Task.yield() }
        try #require(driver.confirmations.count == 1)
        #expect(service.environmentState == .settling && driver.installations == 2)
        service.present(.collapsed)
        #expect(service.requestedPresentation == .all && driver.lastPresentation == .all)
        service.present(.all)
        for _ in 0..<100 where driver.confirmations.count < 2 { await Task.yield() }
        try #require(driver.confirmations.count == 2)
        driver.confirmations.removeFirst().resume(returning: ())
        await Task.yield()
        #expect(service.environmentState == .settling)
        driver.confirmations.removeFirst().resume(returning: ())
        await service.finishEnvironmentRecovery()
        #expect(service.environmentState == .ready && service.message == nil)
        service.environmentDidChange(.layout)
        for _ in 0..<100 where driver.confirmations.isEmpty { await Task.yield() }
        try #require(driver.confirmations.count == 1)
        service.stop()
        driver.confirmations.removeFirst().resume(returning: ())
        await Task.yield()
        #expect(!service.isEnabled && service.environmentState == .ready && service.message == nil)
        #expect(driver.removals == 1 && driver.lastPresentation == .all)
    }
}

@MainActor
private final class MenuBarDriverFixture: MenuBarPartitionDriving {
    var onRequest: ((MenuBarPresentation) -> Void)?
    var onOpenShelf: ((MenuBarShelfScope) -> Void)?
    var installations = 0
    var installedDeepSection = false
    var removals = 0
    var failCollapse = false
    var delayCollapse = false
    var failConfirmation = false
    var deferConfirmation = false
    var confirmationRequests = 0
    var confirmations: [CheckedContinuation<Void, Error>] = []
    var lastPresentation: MenuBarPresentation = .all
    func install(deepSectionEnabled: Bool) { installations += 1; installedDeepSection = deepSectionEnabled; lastPresentation = .all }
    func present(_ state: MenuBarPresentation) async throws {
        if state == .collapsed {
            if failCollapse { throw MenuBarPartitionError.invalidOrder }
            if delayCollapse { try await Task.sleep(for: .milliseconds(25)) }
        }
        try Task.checkCancellation()
        lastPresentation = state
    }
    func remove() { removals += 1; lastPresentation = .all }
    func refreshLabels() {}
    func revealAll() { lastPresentation = .all }
    func confirmRevealedLayout() async throws {
        confirmationRequests += 1
        if failConfirmation { throw MenuBarPartitionError.recoveryUnconfirmed }
        if deferConfirmation { try await withCheckedThrowingContinuation { confirmations.append($0) } }
    }
    func layoutSnapshot() throws -> MenuBarPartitionSnapshot { throw MenuBarPartitionError.unavailable }
}

@MainActor
private final class MenuBarInventoryFixture {
    var requests: [CheckedContinuation<MenuBarInventory, Error>] = []
    func capture() async throws -> MenuBarInventory {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    static func inventory() -> MenuBarInventory {
        .init(id: UUID(), capturedAt: Date(), systemVersion: "Fixture", accessibility: .granted,
              displays: [], items: [], issues: [])
    }
}

@MainActor
private final class MenuBarHotKeyFixture: MenuBarHotKeyDriving {
    var applications = 0
    var stops = 0
    var fail = true
    func apply(shelf: MenuBarShortcutPreset, reveal: MenuBarShortcutPreset, action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32] {
        applications += 1
        return fail ? [.shelf: -9878] : [:]
    }
    func stop() { stops += 1 }
}
