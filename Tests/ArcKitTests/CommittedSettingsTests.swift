@testable import ArcKitApplication
import ArcKitPersistence
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation
import Testing

@Suite("已提交设置", .serialized)
@MainActor
struct CommittedSettingsTests {
    @Test("功能编辑共用一个草稿、撤销历史和事务门禁")
    func featureSettingsTransactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository,
            templateLibrary: NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("templates")))
        await model.waitForPendingChanges()
        func waitForHistory() async throws {
            for _ in 0..<200 {
                if !model.isOperationRunning { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!model.isOperationRunning)
        }
        let initial = model.settings
        let mouse = model.mouseEditor
        let window = model.windowEditor
        mouse.update(actionName: "mouse", coalescingKey: "speed") { $0.globalTuning.speedGain = 1.5 }
        mouse.update(actionName: "mouse", coalescingKey: "speed") { $0.globalTuning.speedGain = 1.8 }
        #expect(mouse.hasUncommittedChanges)
        #expect(!model.finderEditor.hasUncommittedChanges)
        #expect(model.settings.windowManagement == initial.windowManagement)
        window.update(actionName: "window") { $0.windowGap = 24 }
        model.undo()
        try await waitForHistory()
        #expect(window.settings == initial.windowManagement)
        #expect(mouse.settings.globalTuning.speedGain == 1.8)
        model.undo()
        try await waitForHistory()
        #expect(model.settings == initial)
        model.redo()
        try await waitForHistory()
        #expect(mouse.settings.globalTuning.speedGain == 1.8)
        #expect(await model.finishPendingChanges())
        #expect(try repository.load() == model.settings)
        #expect(!mouse.hasUncommittedChanges)
        let before = model.settings
        let lease = try model.operations.begin(.termination)
        mouse.update { $0.globalTuning.speedGain = 2 }
        window.update { $0.windowGap = 32 }
        model.finderEditor.update { $0.defaultTerminal = .iTerm }
        #expect(model.settings == before)
        model.operations.end(lease)
        try repository.database.close()
    }

    @Test("数据备份与设置操作互斥，恢复成功或失败都释放任务并恢复生命周期")
    func dataManagementOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository,
            templateLibrary: NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("assets/templates")))
        let dataModel = DataManagementModel(settingsModel: model,
            backupService: SettingsBackupService(automaticBackupURL: root.appendingPathComponent("automatic.json"),
                                                 managedTemplateDirectory: root.appendingPathComponent("assets/templates")))
        await model.waitForPendingChanges()
        model.update { $0.appearance = .dark }
        #expect(await model.finishPendingChanges())
        var resumed: [Bool] = []
        dataModel.beforeStorageOperation = { _ in
            #expect(model.isOperationRunning && !model.canUndo && !model.canRedo)
            #expect(!(await model.finishPendingChanges())) // 退出不得穿透恢复所持租约。
            let before = model.settings
            model.undo()
            model.update { $0.appearance = .light }
            await dataModel.resetWithAutomaticBackup()
            #expect(model.settings == before)
            do {
                _ = try await dataModel.exportBackup(to: root.appendingPathComponent("blocked.json"))
                Issue.record("数据任务期间不能导出另一份设置")
            } catch { #expect(error as? SettingsBackupError == .operationInProgress) }
            do {
                try await dataModel.performStorageOperation(.clearCache)
                Issue.record("数据任务期间不能开始另一项维护")
            } catch { #expect(error as? SettingsBackupError == .operationInProgress) }
        }
        dataModel.afterStorageOperation = { resumed.append($0) }
        let backup = root.appendingPathComponent("complete.arckitbackup")
        try await dataModel.performStorageOperation(.export(backup))
        #expect(!model.isOperationRunning)
        #expect(dataModel.exportedBackupURLForReveal() == backup)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked.json").path))
        model.update { $0.appearance = .light }
        #expect(await model.finishPendingChanges())
        try await dataModel.performStorageOperation(.restore(backup))
        #expect(model.settings.appearance == .dark)
        #expect(try repository.load().appearance == .dark)
        do {
            try await dataModel.performStorageOperation(.restore(root.appendingPathComponent("missing.arckitbackup")))
            Issue.record("缺失备份必须失败")
        } catch { }
        #expect(!model.isOperationRunning && !dataModel.isOperationRunning)
        #expect(model.settings.appearance == .dark)
        #expect(resumed == [false, true, true])
        guard case .failed = dataModel.transferState else { Issue.record("恢复失败必须保留可见结果"); return }
        dataModel.beforeStorageOperation = nil
        dataModel.afterStorageOperation = nil
        try repository.database.close()
    }

    @Test("设置导入可撤销，恢复失败保留当前配置和原恢复点")
    func settingsTransferAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let backups = SettingsBackupService(automaticBackupURL: root.appendingPathComponent("automatic.json"),
                                            managedTemplateDirectory: root.appendingPathComponent("assets/templates"))
        let model = SettingsModel(store: repository)
        let data = DataManagementModel(settingsModel: model, backupService: backups)
        await model.waitForPendingChanges()
        model.update { $0.appearance = .dark }
        #expect(await model.finishPendingChanges())
        let exported = root.appendingPathComponent("settings.json")
        try await data.exportBackup(to: exported)
        let document = try await data.readBackup(from: exported)
        // 尚未触发防抖保存就导入；旧草稿不能在导入后覆盖新配置。
        model.update { $0.appearance = .light }
        try await data.importBackup(document)
        #expect(model.committedSettings?.appearance == .dark)
        #expect(try backups.loadAutomaticBackup().settings.appearance == .light)
        model.undo()
        let deadline = Date().addingTimeInterval(2)
        while model.isOperationRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isOperationRunning && model.canRedo)
        #expect(model.settings.appearance == .light && model.committedSettings == model.settings)
        #expect(data.transferState == .idle)
        #expect(try repository.load() == model.settings)

        model.update { $0.appearance = .dark }
        #expect(await model.finishPendingChanges())
        let original = try backups.loadAutomaticBackup()
        try repository.database.write { try $0.execute(sql: "CREATE TRIGGER reject_restore BEFORE INSERT ON app_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        await data.restoreAutomaticBackup()
        #expect(!model.isOperationRunning)
        #expect(model.settings.appearance == .dark && model.committedSettings == model.settings)
        #expect(try repository.load() == model.settings)
        #expect(try backups.loadAutomaticBackup().settings == original.settings)
        #expect(try backups.loadAutomaticBackup().createdAt == original.createdAt)
        guard case .failed = data.transferState else { Issue.record("失败回执必须保留"); return }
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER reject_restore") }
        await data.restoreAutomaticBackup()
        #expect(model.settings.appearance == .light && model.committedSettings == model.settings)
        #expect(try backups.loadAutomaticBackup().settings.appearance == .dark)
        await data.resetWithAutomaticBackup()
        #expect(model.isUsingDefaultSettings && model.committedSettings == model.settings)
        #expect(try backups.loadAutomaticBackup().settings.appearance == .light)

        // 在途提交回执改变草稿时，整份替换必须拒绝，保留系统回滚并允许随后正常保存。
        let launchPreference = model.settings.launchAtLoginEnabled
        var rollsBack = false
        let runtime = RuntimeSettingsSession(model: model, didCommit: { _, _ in
            if rollsBack {
                rollsBack = false
                model.update(recordsHistory: false) { $0.launchAtLoginEnabled = launchPreference }
            }
        })
        runtime.start()
        defer { runtime.stop() }
        rollsBack = true
        model.update { $0.launchAtLoginEnabled.toggle() }
        model.flush()
        let operation = try model.operations.begin(.transfer)
        do {
            try await model.replaceSettingsImmediately(with: document.settings, under: operation)
            Issue.record("不能覆盖提交回执生成的系统回滚")
        } catch { #expect(error as? SettingsBackupError == .settingsChangedDuringTransfer) }
        model.operations.end(operation)
        #expect(model.settings.launchAtLoginEnabled == launchPreference)
        #expect(await model.finishPendingChanges())
        #expect(try repository.load() == model.settings)
        try repository.database.close()
    }

    @Test("加载失败时不把默认草稿发布为后台配置")
    func failedLoadDoesNotStartRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("app.sqlite")
        try Data("corrupt".utf8).write(to: file)
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository)
        var applications = 0
        let runtime = RuntimeSettingsSession(model: model, didCommit: { _, _ in applications += 1 })
        runtime.start()
        defer { runtime.stop() }
        await model.waitForPendingChanges()
        #expect(runtime.current == nil)
        #expect(applications == 0)
        try FileManager.default.removeItem(at: file)
        model.reload()
        await model.waitForPendingChanges()
        #expect(runtime.current == model.committedSettings)
        #expect(applications == 1)
    }

    @Test("保存失败不发布配置，重试成功后才推进运行时事实")
    func failedDraftIsNotCommitted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SettingsRepository(directoryURL: root)
        let model = SettingsModel(store: repository)
        var appliedMouse: [MouseEnhancementSettings] = []
        var appliedWindow: [WindowManagementSettings] = []
        var appliedFinder: [FinderRuntimeSettings] = []
        var commits = 0
        var rollbackOnCommit = false
        let runtime = RuntimeSettingsSession(
            model: model,
            didCommit: { previous, current in
                if previous?.mouseEnhancement != current.mouseEnhancement { appliedMouse.append(current.mouseEnhancement) }
                if previous?.windowManagement != current.windowManagement { appliedWindow.append(current.windowManagement) }
                if previous?.finder != current.finder { appliedFinder.append(current.finder) }
                commits += 1
                if rollbackOnCommit {
                    rollbackOnCommit = false
                    model.update(recordsHistory: false) { $0.launchAtLoginEnabled.toggle() }
                }
            }
        )
        runtime.start()
        defer { runtime.stop() }
        await model.waitForPendingChanges()
        let original = model.committedSettings
        model.update {
            $0.showMenuBarIcon = false
            $0.mouseEnhancement.isEnabled.toggle()
            $0.finder.menuConfiguration.isEnabled.toggle()
        }
        #expect(runtime.current == original)
        #expect(commits == 1)
        #expect(model.committedSettings == original)
        try repository.database.write { try $0.execute(sql: "CREATE TRIGGER reject_commit BEFORE INSERT ON mouse_preferences BEGIN SELECT RAISE(FAIL, 'injected'); END") }
        model.flush()
        await model.waitForPendingChanges()
        #expect(model.committedSettings == original)
        #expect(try repository.load() == original)
        #expect(runtime.current == original)
        #expect(commits == 1)
        #expect(appliedMouse.last == original?.mouseEnhancement)
        #expect(appliedFinder.last == original?.finder)
        guard case .failed = model.persistenceState else {
            Issue.record("失败提交必须可见")
            return
        }
        try repository.database.write { try $0.execute(sql: "DROP TRIGGER reject_commit") }
        model.flush()
        await model.waitForPendingChanges()
        #expect(model.committedSettings == model.settings)
        #expect(try repository.load() == model.settings)
        #expect(runtime.current == model.settings)
        #expect(commits == 2)
        #expect(appliedMouse.last == model.settings.mouseEnhancement)
        #expect(appliedFinder.last == model.settings.finder)
        #expect(appliedWindow.count == 1) // 其他域变更不能重启窗口服务。
        model.flush()
        await model.waitForPendingChanges()
        #expect(commits == 2)
        // 模拟登录项系统操作失败，在提交回调中生成回滚草稿。
        rollbackOnCommit = true
        model.update { $0.launchAtLoginEnabled.toggle() }
        model.flush()
        await model.waitForPendingChanges()
        #expect(model.persistenceState == .pending)
        #expect(model.settings != model.committedSettings)
        #expect(runtime.current == model.committedSettings)
        #expect(try repository.load() == runtime.current)
        let deliveredCommits = commits
        runtime.stop()
        model.update { $0.finder.defaultTerminal = .iTerm }
        model.flush()
        await model.waitForPendingChanges()
        #expect(commits == deliveredCommits)
        #expect(runtime.current == nil)
    }
}
