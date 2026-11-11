@testable import ArcKitApplication
import ArcKitPlatform
import ArcKitPersistence
import ArcKitFinder
import AppKit
import Combine
import Foundation
import Testing

@Suite("菜单栏配置与生命周期", .serialized)
struct MenuBarSettingsTests {
    @Test("内部锚点不显示符号或响应点击，收纳开启时保留品牌恢复入口")
    @MainActor func unifiedEntryPolicy() {
        let button = NSButton()
        let target = NSObject()
        button.title = "legacy"; button.image = ArcIconImage.image(.chevronRight)
        button.target = target; button.action = NSSelectorFromString("legacyAction:")
        MenuBarControlAppearance.concealAnchor(button)
        #expect(button.title.isEmpty && button.image == nil && button.action == nil && button.target == nil && !button.isEnabled)
        var settings = AppSettings.defaults
        settings.showMenuBarIcon = false; settings.menuBar.isEnabled = false
        #expect(!settings.menuBarEntryVisible)
        settings.menuBar.isEnabled = true
        #expect(settings.menuBarEntryVisible)
        settings.menuBar.isEnabled = false; settings.showMenuBarIcon = true
        #expect(settings.menuBarEntryVisible)
    }

    @Test("普通应用启停不重置已收起状态，切换中发生变化才撤销")
    @MainActor func applicationChangesPreserveCollection() async throws {
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(driverFactory: { driver },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        service.present(.collapsed); await service.finishPresentation()
        service.applicationsDidChange()
        #expect(service.requestedPresentation == .collapsed && driver.lastPresentation == .collapsed)
        service.present(.all)
        driver.delayCollapse = true
        service.present(.collapsed)
        await Task.yield()
        service.applicationsDidChange()
        try await Task.sleep(for: .milliseconds(40))
        #expect(service.requestedPresentation == .all && driver.lastPresentation == .all && service.pendingPresentation == nil)

    }

    @Test("展开后连续空闲五分钟才收起，输入与再次展开重新计时", arguments: [MenuBarPartitionMode.systemVisibility, .offscreen])
    @MainActor func idleAutoCollapse(mode: MenuBarPartitionMode) async {
        let driver = MenuBarDriverFixture()
        let clock = MenuBarIdleClockFixture()
        let service = MenuBarManagementService(partitionMode: mode, driverFactory: { driver },
            uptime: { clock.now }, inputIdleTime: { clock.idle }, idleTicks: { clock.publisher },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        #expect(clock.isRunning)
        clock.tick(at: 299.9, idle: 1_000)
        #expect(service.pendingPresentation == nil && driver.collapseRequests == 0)
        clock.tick(at: 300, idle: 0) // 模拟任意键盘、鼠标或触控板输入。
        clock.tick(at: 599.9, idle: 299.9)
        #expect(service.requestedPresentation == .all && driver.collapseRequests == 0)
        // 无关设置提交不能延长同一轮空闲计时。
        service.apply(.init(isEnabled: true, opacity: 0.6))
        clock.tick(at: 600, idle: 300)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed && driver.collapseRequests == 1)
        #expect(!clock.isRunning)
        clock.tick(at: 900, idle: 600)
        service.toggleCollection(); await service.finishPresentation()
        #expect(service.requestedPresentation == (mode.supportsSections ? .expanded : .all))
        clock.tick(at: 1_199.9, idle: 899.9)
        #expect(driver.collapseRequests == 1)
        clock.tick(at: 1_200, idle: 900)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed && driver.collapseRequests == 2)
    }

    @Test("自动收起在停用、休眠和恢复失败时取消，恢复与显示全部重新等待五分钟")
    @MainActor func idleAutoCollapseLifecycle() async {
        let driver = MenuBarDriverFixture()
        let clock = MenuBarIdleClockFixture()
        let service = MenuBarManagementService(driverFactory: { driver },
            uptime: { clock.now }, inputIdleTime: { clock.idle }, idleTicks: { clock.publisher },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        service.apply(.init(isEnabled: false))
        clock.tick(at: 600, idle: 600)
        #expect(!clock.isRunning && driver.collapseRequests == 0)
        service.apply(.init(isEnabled: true))
        service.environmentDidChange(.sleep)
        service.environmentDidChange(.layout)
        clock.tick(at: 1_200, idle: 1_200)
        #expect(!clock.isRunning && driver.collapseRequests == 0)
        driver.failConfirmation = true
        service.environmentDidChange(.wake); await service.finishEnvironmentRecovery()
        #expect(service.environmentState == .unconfirmed && !clock.isRunning)
        clock.tick(at: 1_800, idle: 1_800)
        driver.failConfirmation = false
        service.present(.all); await service.finishEnvironmentRecovery()
        #expect(service.environmentState == .ready && clock.isRunning)
        clock.tick(at: 2_099.9, idle: 2_099.9)
        #expect(driver.collapseRequests == 0)
        clock.tick(at: 2_100, idle: 2_100)
        await service.finishPresentation()
        #expect(driver.collapseRequests == 1)
        service.present(.all)
        #expect(clock.isRunning)
        service.stop()
        clock.tick(at: 2_400, idle: 2_400)
        #expect(!clock.isRunning && driver.collapseRequests == 1 && driver.lastPresentation == .all)
    }

    @Test("自动收起失败不循环重试，手动展开后可恢复；预览不启动空闲检查")
    @MainActor func idleAutoCollapseFailureAndPreview() async {
        let driver = MenuBarDriverFixture()
        let clock = MenuBarIdleClockFixture()
        let preview = MenuBarManagementService(isPreview: true, idleTicks: { clock.publisher })
        preview.apply(.init(isEnabled: true))
        #expect(!clock.isRunning)
        let service = MenuBarManagementService(driverFactory: { driver },
            uptime: { clock.now }, inputIdleTime: { clock.idle }, idleTicks: { clock.publisher },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        driver.failCollapse = true
        clock.tick(at: 300, idle: 300)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .all && service.message != nil && driver.collapseRequests == 1)
        service.apply(.init(isEnabled: true, opacity: 0.6))
        clock.tick(at: 600, idle: 600)
        #expect(!clock.isRunning && driver.collapseRequests == 1)
        driver.failCollapse = false
        service.present(.all)
        let recorder = UUID()
        service.setShortcutRecording(owner: recorder, active: true)
        clock.tick(at: 900, idle: 900)
        #expect(service.pendingPresentation == nil && driver.collapseRequests == 1)
        service.setShortcutRecording(owner: recorder, active: false)
        clock.tick(at: 1_199.9, idle: 1_199.9)
        #expect(driver.collapseRequests == 1)
        clock.tick(at: 1_200, idle: 1_200)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed && service.message == nil && driver.collapseRequests == 2)
    }

    @Test("自动收起只消费已提交开关与时长，修改重新计时，关闭取消旧自动请求但不影响手动收起")
    @MainActor func idleAutoCollapseConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("templates")))
        await model.waitForPendingChanges()
        let driver = MenuBarDriverFixture(), clock = MenuBarIdleClockFixture()
        let service = MenuBarManagementService(driverFactory: { driver },
            uptime: { clock.now }, inputIdleTime: { clock.idle }, idleTicks: { clock.publisher },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        let session = RuntimeSettingsSession(model: model) { _, current in service.apply(current.menuBar) }
        session.start()
        defer { session.stop(); service.stop(); try? repository.database.close() }
        model.menuBarEditor.update { $0.isEnabled = true; $0.autoCollapseEnabled = false }
        #expect(await model.finishPendingChanges())
        clock.tick(at: 600, idle: 600)
        #expect(!clock.isRunning && driver.collapseRequests == 0)
        try repository.database.write { try $0.execute(sql: "CREATE TRIGGER reject_auto_collapse BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        model.menuBarEditor.update { $0.autoCollapseEnabled = true; $0.autoCollapseDelayMinutes = 2 }
        #expect(!(await model.finishPendingChanges()))
        #expect(!clock.isRunning)
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER reject_auto_collapse") }
        #expect(await model.finishPendingChanges())
        clock.tick(at: 719.9, idle: 719.9)
        #expect(service.pendingPresentation == nil && driver.collapseRequests == 0)
        // 修改已提交时长后从当前时刻重新等待，不沿用已经累计的空闲时间。
        model.menuBarEditor.update { $0.autoCollapseDelayMinutes = 1 }
        #expect(await model.finishPendingChanges())
        clock.tick(at: 779.8, idle: 779.8)
        #expect(service.pendingPresentation == nil)
        clock.tick(at: 780, idle: 780)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed && driver.collapseRequests == 1)
        service.present(.all)
        driver.delayCollapse = true
        clock.tick(at: 840, idle: 840)
        await Task.yield()
        #expect(service.pendingPresentation == .collapsed)
        // 关闭配置直接送入运行入口，取消已排队或进行中的自动请求。
        var disabled = model.menuBarEditor.settings
        disabled.autoCollapseEnabled = false
        service.apply(disabled)
        try await Task.sleep(for: .milliseconds(40))
        #expect(!clock.isRunning && service.pendingPresentation == nil && driver.lastPresentation == .all)
        service.present(.collapsed); await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed && !clock.isRunning)
    }

    @Test("自动收起的 SQLite 默认值只迁移一次，保留既有设置且不推进 Host 代次")
    func idleAutoCollapseMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var settings = try repository.load()
        settings.menuBar.isEnabled = true; settings.menuBar.collectedApplications = ["app.one"]
        let before = try repository.save(settings)
        try repository.database.write { db in
            try db.execute(sql: """
                ALTER TABLE menu_bar_preferences DROP COLUMN autoCollapseEnabled;
                ALTER TABLE menu_bar_preferences DROP COLUMN autoCollapseDelayMinutes;
                UPDATE menu_bar_preferences SET _types=json_remove(_types,'$.autoCollapseEnabled','$.autoCollapseDelayMinutes');
                DELETE FROM grdb_migrations WHERE identifier='menu-bar-auto-collapse-v1';
                """)
        }
        try repository.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        #expect(migrated.settings == settings && migrated.revision.runtime == before.revision.runtime)
        #expect(migrated.settings.menuBar.autoCollapseEnabled && migrated.settings.menuBar.autoCollapseDelayMinutes == 5)
        settings.menuBar.autoCollapseEnabled = false; settings.menuBar.autoCollapseDelayMinutes = 12
        try upgraded.save(settings); try upgraded.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        #expect(try reopened.load() == settings)
        try reopened.database.close()
    }

    @Test("启用后直接展开，单次点击收起，关闭失败保持原状态且可重试")
    @MainActor func singleButtonWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("templates")))
        await model.waitForPendingChanges()
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(partitionMode: .systemVisibility, driverFactory: { driver })
        let session = RuntimeSettingsSession(model: model) { _, current in service.apply(current.menuBar) }
        session.start()
        defer { session.stop(); service.stop() }
        let flow = MenuBarWorkflow(editor: model.menuBarEditor, service: service)
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_setup BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL,'fixture save failure'); END")
        }
        await flow.setEnabled(true)
        #expect(flow.error != nil && !flow.isWorking && driver.installations == 0)
        #expect(model.menuBarEditor.committedSettings?.isEnabled == false)
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER fail_setup") }
        await flow.retry()
        #expect(flow.error == nil && driver.installations == 1 && service.requestedPresentation == .all)
        driver.failCollapse = true
        flow.toggle(); await service.finishPresentation()
        #expect(service.message != nil && service.requestedPresentation == .all)
        driver.failCollapse = false
        flow.toggle(); await service.finishPresentation()
        #expect(service.message == nil && service.requestedPresentation == .collapsed)
        flow.toggle(); await service.finishPresentation()
        #expect(service.requestedPresentation == .all)
        service.toggleCollection(); await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed)

        // 关闭保存失败时不能先撤控件；开关仍对应已提交状态。
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_disable BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL,'fixture save failure'); END")
        }
        await flow.setEnabled(false)
        #expect(flow.error != nil && model.menuBarEditor.committedSettings?.isEnabled == true)
        #expect(service.isEnabled && driver.removals == 0)
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER fail_disable") }
        await flow.retry()
        #expect(model.menuBarEditor.committedSettings?.isEnabled == false && driver.removals == 1)
        #expect(service.requestedPresentation == .all && service.canSearchAllIcons)
        try repository.database.close()
    }

    @Test("离开页面后丢弃迟到保存反馈，不追加原生动作")
    @MainActor func setupCancellation() async throws {
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(partitionMode: .systemVisibility, driverFactory: { driver })
        defer { service.stop() }
        var draft = MenuBarSettings(isEnabled: true)
        let committed = draft
        var completion: CheckedContinuation<Bool, Never>?
        let editor = SettingsEditor(changes: ObservableObjectPublisher(), read: { draft }, committed: { committed },
            update: { _, _, edit in edit(&draft) }, save: { await withCheckedContinuation { completion = $0 } }, failure: { "fixture failure" })
        service.apply(draft); service.present(.collapsed); await service.finishPresentation()
        let flow = MenuBarWorkflow(editor: editor, service: service)
        let task = Task { await flow.setEnabled(false) }
        for _ in 0..<100 where completion == nil { await Task.yield() }
        let save = try #require(completion)
        flow.leave(); save.resume(returning: false)
        await task.value
        #expect(!flow.isWorking && flow.error == nil && service.requestedPresentation == .collapsed)
    }

    @Test("快捷键独立启停，搜索不创建分隔线，收起展开遵守系统模式并取消旧请求",
          arguments: [MenuBarPartitionMode.systemVisibility, .offscreen])
    @MainActor func independentShortcutsAndToggle(mode: MenuBarPartitionMode) async throws {
        let driver = MenuBarDriverFixture()
        let hotKeys = MenuBarHotKeyFixture(); hotKeys.fail = false
        let panel = ShortcutShelfPanel()
        let service = MenuBarManagementService(partitionMode: mode, driverFactory: { driver }, hotKeyFactory: { hotKeys },
            captureInventory: { _ in MenuBarInventoryFixture.inventory() }, shelfPanelFactory: { _, _ in panel },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        var settings = MenuBarSettings(deepSectionEnabled: true,
            shelfShortcut: .init(keyCode: 38, keyEquivalent: "J", modifiers: [.command, .option]),
            revealShortcut: .init(keyCode: 32, keyEquivalent: "U", modifiers: [.control, .option]),
            toggleShortcut: .init(keyCode: 17, keyEquivalent: "T", modifiers: [.control, .option]), shortcutsEnabled: true)
        service.apply(settings)
        #expect(!service.isEnabled && driver.installations == 0)
        #expect(Set(hotKeys.bindings.keys) == [.shelf] && service.registeredHotKeyActions == [.shelf])
        hotKeys.callback?(.shelf); await service.finishItemRequest()
        #expect(panel.isVisible && driver.installations == 0)
        let recorder = UUID()
        service.setShortcutRecording(owner: recorder, active: true)
        #expect(service.registeredHotKeyActions.isEmpty)
        service.setShortcutRecording(owner: recorder, active: false)
        #expect(service.registeredHotKeyActions == [.shelf])

        settings.isEnabled = true
        service.apply(settings)
        #expect(driver.installations == 1 && hotKeys.bindings.count == 3)
        hotKeys.callback?(.toggle); await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed)
        hotKeys.callback?(.toggle); await service.finishPresentation()
        #expect(service.requestedPresentation == (mode == .systemVisibility ? .all : .expanded))
        driver.delayCollapse = true
        hotKeys.callback?(.toggle)
        await Task.yield()
        service.toggleCollection()
        service.toggleCollection()
        await service.finishPresentation()
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.lastPresentation == .collapsed && service.requestedPresentation == .collapsed)
        service.toggleCollection(); await service.finishPresentation()
        #expect(service.requestedPresentation == (mode == .systemVisibility ? .all : .expanded))

        settings.isEnabled = false
        service.apply(settings)
        #expect(driver.removals == 1 && service.registeredHotKeyActions == [.shelf])
        #expect(!service.isEnabled)
        hotKeys.callback?(.shelf); await service.finishItemRequest()
        #expect(panel.isVisible)
        settings.shortcutsEnabled = false
        service.apply(settings)
        #expect(hotKeys.bindings.isEmpty && service.registeredHotKeyActions.isEmpty)
        #expect(panel.isVisible) // 关闭快捷键不取消已经打开的手动搜索。
    }

    @Test("旧快捷键开关只迁移一次，保留原组合且不推进 Host 代次", arguments: [false, true])
    func independentShortcutMigration(wasEnabled: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        var expected = try repository.load()
        expected.menuBar.isEnabled = wasEnabled
        expected.menuBar.opacity = 0.5
        expected.menuBar.shelfShortcut = .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option])
        let before = try repository.save(expected)
        try repository.database.write { db in
            try db.execute(sql: """
                ALTER TABLE menu_bar_preferences DROP COLUMN shortcutsEnabled;
                ALTER TABLE menu_bar_preferences DROP COLUMN toggleShortcut;
                UPDATE menu_bar_preferences SET _types=json_remove(_types,'$.shortcutsEnabled','$.toggleShortcut');
                DELETE FROM grdb_migrations WHERE identifier='menu-bar-independent-shortcuts-v1';
                """)
        }
        try repository.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        expected.menuBar.shortcutsEnabled = wasEnabled
        let migrated = try upgraded.loadSnapshot()
        #expect(migrated.settings == expected && migrated.revision.runtime == before.revision.runtime)
        #expect(migrated.settings.menuBar.toggleShortcut == .disabled)
        expected.menuBar.isEnabled = false
        expected.menuBar.shortcutsEnabled = true
        expected.menuBar.toggleShortcut = .init(keyCode: 17, keyEquivalent: "T", modifiers: [.control, .option])
        try upgraded.save(expected)
        var duplicate = expected
        duplicate.menuBar.toggleShortcut = duplicate.menuBar.shelfShortcut
        #expect(throws: (any Error).self) { try upgraded.save(duplicate) }
        try upgraded.database.close()
        let reopened = SettingsRepository(directoryURL: root)
        #expect(try reopened.load() == expected)
        #expect(try reopened.load().menuBar.activeShortcuts.keys.sorted(by: { $0.rawValue < $1.rawValue }) == [.shelf])
        try reopened.database.close()
    }

    @Test("自由录制拒绝裸键和重复组合，支持键盘进入、取消、停用及禁用状态")
    @MainActor func customShortcutRecording() throws {
        let control = KeyboardShortcutRecorderControl()
        let duplicate = HotKeyChord(keyCode: 40, keyEquivalent: "K", modifiers: .command)
        var saved: [HotKeyChord] = []
        control.onChange = { saved.append($0) }
        control.configure(binding: .disabled, duplicateShortcuts: [duplicate.shortcutIdentifier], rejectDuplicates: true)
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code))
        }
        control.keyDown(with: try key(36, "\r"))
        control.keyDown(with: try key(40, "k"))
        #expect(saved.isEmpty)
        #expect(control.performKeyEquivalent(with: try key(40, "k", .command)))
        #expect(saved.isEmpty)
        control.keyDown(with: try key(53, ""))
        #expect(saved.isEmpty)
        #expect(control.accessibilityPerformPress())
        #expect(control.performKeyEquivalent(with: try key(38, "j", [.command, .option])))
        #expect(saved.last == HotKeyChord(keyCode: 38, keyEquivalent: "J", modifiers: [.command, .option]))
        #expect(control.accessibilityPerformPress())
        control.keyDown(with: try key(51, ""))
        #expect(saved.count == 2 && saved.last?.isEnabled == false)
        control.configure(binding: .disabled, duplicateShortcuts: [], isEnabled: false)
        #expect(!control.accessibilityPerformPress())
        control.keyDown(with: try key(38, "j", [.command, .option]))
        #expect(saved.count == 2)
    }

    @Test("系统溢出使用有界分段，不创建深度区或提供失真的普通区筛选")
    @MainActor func systemVisibilityPolicy() throws {
        let displays = [
            MenuBarDisplay(id: 1, name: "Notched", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           topBand: CGRect(x: 0, y: 0, width: 1512, height: 34),
                           notch: CGRect(x: 662, y: 0, width: 188, height: 34), scale: 2),
            MenuBarDisplay(id: 2, name: "Wide", frame: CGRect(x: 0, y: -1440, width: 2560, height: 1440),
                           topBand: CGRect(x: 0, y: -1440, width: 2560, height: 31), notch: nil, scale: 1)
        ]
        let plan = try MenuBarOverflowPlan(displays: displays)
        #expect(plan.segmentLength == 432 && plan.segmentCount == 6)
        #expect(plan.segmentLength * CGFloat(plan.segmentCount) >= 2560)
        #expect(plan.segmentCount - 1 <= MenuBarOverflowPlan.spacerCapacity)
        let unsupported = MenuBarDisplay(id: 3, name: "Too wide", frame: CGRect(x: 0, y: 0, width: 7680, height: 2160),
            topBand: CGRect(x: 0, y: 0, width: 7680, height: 32), notch: nil, scale: 1)
        #expect(throws: MenuBarPartitionError.self) { try MenuBarOverflowPlan(displays: displays + [unsupported]) }
        #expect(throws: MenuBarPartitionError.self) { try MenuBarOverflowPlan(displays: []) }
        let driver = MenuBarDriverFixture()
        let service = MenuBarManagementService(partitionMode: .systemVisibility, driverFactory: { driver })
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

    @Test("旧收纳名单仅迁移一次，持久化和备份不依赖后续系统顺序")
    func collectionMembershipMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = SettingsRepository(directoryURL: root)
        var settings = try initial.load(); settings.windowManagement.windowGap = 18; settings.menuBar.isEnabled = true
        try initial.save(settings)
        try initial.database.write { db in
            try db.execute(sql: "ALTER TABLE menu_bar_preferences DROP COLUMN collectedApplications")
            try db.execute(sql: "UPDATE menu_bar_preferences SET _types=json_remove(_types,'$.collectedApplications')")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='menu-bar-collection-membership-v1'")
        }
        try initial.database.close()
        let database = ArcKitDatabase(paths: ArcKitStoragePaths(root: root), migrate: {
            try ApplicationStorageMigrations.migrate($0, legacyMenuBarCollection: { ["app.one", "app.two"] })
        })
        let migrated = SettingsRepository(database: database)
        #expect(try migrated.load().menuBar.collectedApplications == ["app.one", "app.two"])
        #expect(try migrated.load().windowManagement.windowGap == 18)
        var changed = try migrated.load(); changed.menuBar.collectedApplications = ["app.two"]
        try migrated.save(changed); try database.close()
        let reopened = SettingsRepository(directoryURL: root)
        #expect(try reopened.load() == changed)
        let backup = try StorageMaintenance(database: reopened.database).backup(full: true)
        changed.menuBar.collectedApplications = []
        try reopened.save(changed)
        try StorageMaintenance(database: reopened.database).restore(backup)
        #expect(try reopened.load().menuBar.collectedApplications == ["app.two"])
        try reopened.database.close()
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
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('menu-bar-shortcuts-v1','menu-bar-custom-shortcuts-v1')")
        }
        try beforeShortcuts.database.close()
        let withShortcuts = SettingsRepository(directoryURL: root)
        #expect(try withShortcuts.load().menuBar.shelfShortcut == .disabled)
        #expect(try withShortcuts.load().menuBar.revealShortcut == .disabled)
        try withShortcuts.database.write { db in
            try db.execute(sql: """
                UPDATE menu_bar_preferences SET shelfShortcut='controlOptionShiftM', revealShortcut='controlOptionCommandM',
                    _types=json_set(_types,'$.shelfShortcut','text','$.revealShortcut','text');
                DELETE FROM grdb_migrations WHERE identifier='menu-bar-custom-shortcuts-v1';
                """)
        }
        try withShortcuts.database.close()
        let upgraded = SettingsRepository(directoryURL: root)
        let migrated = try upgraded.loadSnapshot()
        #expect(migrated.settings.menuBar.shelfShortcut == .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option, .shift]))
        #expect(migrated.settings.menuBar.revealShortcut == .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option, .command]))
        #expect(migrated.revision.runtime == previous.revision.runtime)
        var changed = original
        changed.menuBar = .init(isEnabled: true, deepSectionEnabled: true, style: .floating, opacity: 0.55, cornerRadius: 12, shelfShortcut: .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option]), revealShortcut: .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option, .shift]), autoCollapseEnabled: false, autoCollapseDelayMinutes: 12)
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
        for delay in [0, 61] {
            var invalid = changed; invalid.menuBar.autoCollapseDelayMinutes = delay
            #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        }
        for field in ["autoCollapseEnabled", "autoCollapseDelayMinutes"] {
            var missing = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed.menuBar)) as? [String: Any])
            missing.removeValue(forKey: field)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MenuBarSettings.self, from: JSONSerialization.data(withJSONObject: missing)) }
        }
        var invalid = changed; invalid.menuBar.opacity = 2
        #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        invalid = changed; invalid.menuBar.revealShortcut = invalid.menuBar.shelfShortcut
        #expect(throws: (any Error).self) { try upgraded.save(invalid) }
        invalid = changed; invalid.menuBar.shelfShortcut = .init(keyCode: 38, keyEquivalent: "J", modifiers: .shift)
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
        model.menuBarEditor.update { $0.shelfShortcut = .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option]) }
        #expect(await model.finishPendingChanges())
        #expect(hotKeys.applications == 0 && driver.installations == 0)
        try repository.database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_menu_bar BEFORE INSERT ON menu_bar_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END")
        }
        model.menuBarEditor.update { $0.isEnabled = true; $0.shortcutsEnabled = true }
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
        let firstRecorder = UUID(), secondRecorder = UUID()
        service.setShortcutRecording(owner: firstRecorder, active: true)
        service.setShortcutRecording(owner: secondRecorder, active: true)
        #expect(service.isRecordingShortcut && hotKeys.stops == 1)
        model.menuBarEditor.update { $0.shelfShortcut = .init(keyCode: 38, keyEquivalent: "J", modifiers: [.command, .option]) }
        #expect(await model.finishPendingChanges())
        #expect(hotKeys.applications == 2)
        service.setShortcutRecording(owner: firstRecorder, active: false)
        #expect(service.isRecordingShortcut && hotKeys.applications == 2)
        service.setShortcutRecording(owner: secondRecorder, active: false)
        service.setShortcutRecording(owner: firstRecorder, active: false)
        #expect(!service.isRecordingShortcut && hotKeys.applications == 3)
        model.menuBarEditor.update { $0.opacity = 0.5 }
        #expect(await model.finishPendingChanges())
        #expect(driver.installations == 1)
        service.present(.collapsed)
        await service.finishPresentation()
        #expect(service.requestedPresentation == .collapsed)
        model.menuBarEditor.update { $0.isEnabled = false; $0.shortcutsEnabled = false }
        #expect(await model.finishPendingChanges())
        #expect(driver.removals == 1 && !service.isEnabled && hotKeys.stops == 2)
        try repository.database.close()
    }

    @Test("调试不构造系统控件，退出取消迟到的收起，布局失败恢复全部")
    @MainActor func previewCancellationAndFailure() async {
        let driver = MenuBarDriverFixture()
        var constructions = 0
        var hotKeyConstructions = 0
        let preview = MenuBarManagementService(isPreview: true, driverFactory: { constructions += 1; return driver },
            hotKeyFactory: { hotKeyConstructions += 1; return MenuBarHotKeyFixture() })
        preview.apply(.init(isEnabled: true, shelfShortcut: .init(keyCode: 46, keyEquivalent: "M", modifiers: [.control, .option]), shortcutsEnabled: true))
        preview.toggleShelf(scope: .all)
        preview.present(.collapsed)
        #expect(constructions == 0 && hotKeyConstructions == 0 && !preview.isEnabled && !preview.canSearchAllIcons)
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
        let service = MenuBarManagementService(driverFactory: { driver }, captureInventory: { _ in try await capture.capture() }, shelfPanelFactory: { _, _ in ShortcutShelfPanel() },
            workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
        defer { service.stop() }
        service.apply(.init(isEnabled: true))
        service.toggleShelf(scope: .all)
        for _ in 0..<100 where capture.requests.isEmpty { await Task.yield() }
        try #require(capture.requests.count == 1)
        driver.delayCollapse = true
        service.present(.collapsed)
        await Task.yield()
        service.environmentDidChange(.layout)
        for _ in 0..<100 where driver.confirmations.isEmpty { await Task.yield() }
        try #require(driver.confirmations.count == 1)
        #expect(service.environmentState == .settling && service.requestedPresentation == .all)
        #expect(service.shelfModel.inventoryID == nil && !service.shelfModel.isLoading)

        // 新清单仍可独立发现；旧 AX 捕获即使忽略取消，也不能覆盖新请求或结束其 loading。
        service.toggleShelf(scope: .all)
        for _ in 0..<100 where capture.requests.count < 2 { await Task.yield() }
        try #require(capture.requests.count == 2)
        let stale = capture.requests.removeFirst()
        stale.resume(returning: MenuBarInventoryFixture.inventory())
        await Task.yield()
        #expect(service.shelfModel.inventoryID == nil && service.shelfModel.isLoading)
        let current = MenuBarInventoryFixture.inventory()
        capture.requests.removeFirst().resume(returning: current)
        for _ in 0..<100 where service.shelfModel.isLoading { await Task.yield() }
        #expect(service.shelfModel.inventoryID == current.id)

        service.environmentDidChange(.layout)
        for _ in 0..<100 where driver.confirmations.count < 2 { await Task.yield() }
        try #require(driver.confirmations.count == 2)
        driver.confirmations.removeFirst().resume(returning: ())
        await Task.yield()
        #expect(service.environmentState == .settling && service.shelfModel.inventoryID == nil)
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
        #expect(service.environmentState == .sleeping && service.requestedPresentation == .all)
        #expect(driver.confirmationRequests == 0 && !service.shelfModel.isLoading)
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
    var installations = 0
    var installedDeepSection = false
    var removals = 0
    var failCollapse = false
    var collapseRequests = 0
    var delayCollapse = false
    var failConfirmation = false
    var deferConfirmation = false
    var confirmationRequests = 0
    var confirmations: [CheckedContinuation<Void, Error>] = []
    var lastPresentation: MenuBarPresentation = .all
    func install(deepSectionEnabled: Bool) { installations += 1; installedDeepSection = deepSectionEnabled; lastPresentation = .all }
    func present(_ state: MenuBarPresentation) async throws {
        if state == .collapsed {
            collapseRequests += 1
            if failCollapse { throw MenuBarPartitionError.invalidOrder }
            if delayCollapse {
                lastPresentation = .collapsed // 模拟已改宽度、尚未完成回读的原生请求。
                try await Task.sleep(for: .milliseconds(25))
            }
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
private final class MenuBarIdleClockFixture {
    var now: TimeInterval = 0
    var idle: TimeInterval = 0
    private let ticks = PassthroughSubject<Void, Never>()
    private(set) var isRunning = false
    var publisher: AnyPublisher<Void, Never> {
        ticks.handleEvents(receiveSubscription: { [weak self] _ in self?.isRunning = true },
            receiveCancel: { [weak self] in self?.isRunning = false }).eraseToAnyPublisher()
    }
    func tick(at time: TimeInterval, idle: TimeInterval) {
        now = time; self.idle = idle
        ticks.send(())
    }
}

@MainActor
private final class MenuBarInventoryFixture {
    var requests: [CheckedContinuation<MenuBarInventory, Error>] = []
    func capture() async throws -> MenuBarInventory {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    static func inventory() -> MenuBarInventory {
        .init(id: UUID(), capturedAt: Date(), systemVersion: "Fixture", accessibility: .granted,
              displays: [.init(id: 1, name: "Fixture", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                  topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: nil, scale: 2)], items: [], issues: [])
    }
}

@MainActor
private final class MenuBarHotKeyFixture: MenuBarHotKeyDriving {
    var applications = 0
    var stops = 0
    var fail = true
    var bindings: [MenuBarHotKeyAction: HotKeyChord] = [:]
    var callback: ((MenuBarHotKeyAction) -> Void)?
    func apply(_ shortcuts: [MenuBarHotKeyAction: HotKeyChord], action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32] {
        applications += 1
        bindings = shortcuts; callback = action
        return fail ? [.shelf: -9878] : [:]
    }
    func stop() { stops += 1; bindings = [:]; callback = nil }
}

@MainActor
private final class ShortcutShelfPanel: MenuBarShelfPresenting {
    var onDismiss: (() -> Void)?
    var isVisible = false
    func show() throws -> UInt32 { isVisible = true; return 1 }
    func close() { isVisible = false }
}
