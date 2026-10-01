@testable import ArcKitFinder
@testable import ArcKitFinderSync
@testable import ArcKitFinderRuntime
import ArcKitPlatform
import AppKit
import Foundation
import Testing

@Suite("Finder 文件安全与执行边界", .serialized)
struct FinderTests {
    @MainActor
    @Test("撤下内置模板后隐藏失效菜单，自定义模板仍可导入并创建文件")
    func removedBuiltInTemplateKeepsCustomImportWorking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("created", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("会议记录.md")
        let content = Data("# 会议记录\n".utf8)
        try content.write(to: source)
        let library = NewFileTemplateLibrary(baseDirectory: root.appendingPathComponent("templates"))
        let imported = try library.importTemplate(from: source, sortOrder: 0)
        var settings = FinderRuntimeSettings.defaults
        let removed = ConfigurableNewFileTemplate(
            id: "pages", displayName: "Pages", fileExtension: "pages", sortOrder: 1,
            templateSource: .builtInResource("pages.pages")
        )
        settings.menuConfiguration.fileTemplates = [imported, removed]
        #expect(settings.menuConfiguration.enabledFileTemplates.map(\.id) == [imported.id])
        let created = try NewFileCreationService().createFile(
            templateID: imported.id, directoryPath: destination.path, settings: settings
        )
        #expect(try Data(contentsOf: created.fileURL) == content)
        #expect(try Data(contentsOf: source) == content)
        #expect(throws: (any Error).self) {
            try NewFileCreationService().createFile(templateID: removed.id, directoryPath: destination.path, settings: settings)
        }
    }

    @MainActor
    @Test("菜单选择控制三类资源入口，取消选择或停用条目后拒绝旧请求")
    func resourceMenusFollowSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let child = root.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = FinderRuntimeSettings.defaults
        settings.menuConfiguration.fileTemplates = Array(settings.menuConfiguration.enabledFileTemplates.prefix(2))
        #expect(settings.menuConfiguration.fileTemplates.count == 2)
        settings.menuConfiguration.favoriteApplications = [
            FavoriteApplication(displayName: "应用一", bundleIdentifier: "test.one", sortOrder: 0),
            FavoriteApplication(displayName: "应用二", bundleIdentifier: "test.two", sortOrder: 1)
        ]
        settings.menuConfiguration.favoriteDirectories = [
            FavoriteDirectory(name: "目录", path: root.path, displayMode: .showChildDirectories),
            FavoriteDirectory(name: "子目录", path: child.path)
        ]
        settings.menuConfiguration.modules = FinderMenuModuleID.allCases.map {
            .init(moduleID: $0, enabled: [.newFile, .favoriteApps, .favoriteDirectories].contains($0), sortOrder: $0.defaultOrder)
        }
        let context = FinderMenuBuildContext(hasSelection: true, selectedItemCount: 1, selectedFolderCount: 1)
        func modules(_ snapshot: FinderExtensionSnapshot) throws -> [FinderMenuModuleID] {
            let transported = try JSONDecoder().decode(FinderExtensionSnapshot.self, from: JSONEncoder().encode(snapshot))
            return FinderMenuTreeBuilder.buildEntries(state: .init(snapshot: transported), context: context.targetContext).compactMap {
                if case let .submenu(_, _, moduleID, _, _) = $0 { return moduleID }
                return nil
            }
        }
        let snapshot = FinderExtensionSnapshot.make(settings: settings)
        #expect(try modules(snapshot) == [.newFile, .favoriteApps, .favoriteDirectories])
        let requests: [FinderCommandRequest] = [
            .init(payload: .createNewFile(.init(templateID: settings.menuConfiguration.fileTemplates[0].id, targetPath: root.path))),
            .init(payload: .openWithApp(.init(targetPath: root.path, favoriteApplication: settings.menuConfiguration.favoriteApplications[0]))),
            .init(payload: .openPath(.init(targetPath: root.path)))
        ]
        for request in requests {
            try FinderCommandDispatcher.validateAvailability(of: request, settings: settings)
            var unchecked = settings
            let index = try #require(unchecked.menuConfiguration.modules.firstIndex { $0.moduleID == request.kind.menuModule })
            unchecked.menuConfiguration.modules[index].isEnabled = false
            #expect(try !modules(.make(settings: unchecked)).contains(request.kind.menuModule))
            #expect(throws: (any Error).self) { try FinderCommandDispatcher.validateAvailability(of: request, settings: unchecked) }
        }
        var disabled = settings
        disabled.menuConfiguration.fileTemplates[0].enabled = false
        disabled.menuConfiguration.favoriteApplications[0].enabled = false
        disabled.menuConfiguration.favoriteDirectories[0].enabled = false
        #expect(try modules(.make(settings: disabled)) == [.newFile, .favoriteApps, .favoriteDirectories])
        for request in requests {
            #expect(throws: (any Error).self) { try FinderCommandDispatcher.validateAvailability(of: request, settings: disabled) }
        }
        // 模块勾选与目录展示方式共同控制下级内容，合法子项仍可执行。
        let childRequest = FinderCommandRequest(payload: .openPath(.init(targetPath: child.path)))
        settings.menuConfiguration.favoriteDirectories.removeLast()
        try FinderCommandDispatcher.validateAvailability(of: childRequest, settings: settings)
        settings.menuConfiguration.favoriteDirectories[0].displayMode = .submenuOnly
        #expect(throws: (any Error).self) { try FinderCommandDispatcher.validateAvailability(of: childRequest, settings: settings) }
        settings.menuConfiguration.isEnabled = false
        for request in requests {
            #expect(throws: (any Error).self) { try FinderCommandDispatcher.validateAvailability(of: request, settings: settings) }
        }
        disabled.menuConfiguration.fileTemplates = []
        disabled.menuConfiguration.favoriteApplications = []
        disabled.menuConfiguration.favoriteDirectories = []
        #expect(try modules(.make(settings: disabled)).isEmpty)
        var unavailable = snapshot
        for index in unavailable.fileTemplates.indices { unavailable.fileTemplates[index].isVisible = false }
        for index in unavailable.favoriteApplications.indices { unavailable.favoriteApplications[index].isVisible = false }
        for index in unavailable.favoriteDirectories.indices { unavailable.favoriteDirectories[index].isVisible = false }
        #expect(try modules(unavailable).isEmpty)
    }

    @MainActor
    @Test("工具栏保留选区或本次目录，缺失目标时只允许常用目录导航")
    func toolbarMenuKeepsCapturedTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-toolbar-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("中文 子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("文件.txt")
        try Data().write(to: file)
        var settings = FinderRuntimeSettings.defaults
        settings.menuConfiguration.favoriteDirectories = [FavoriteDirectory(name: "测试目录", path: root.path)]
        settings.menuConfiguration.fileTemplates = []
        settings.menuConfiguration.favoriteApplications = []
        for i in settings.menuConfiguration.modules.indices {
            settings.menuConfiguration.modules[i].isEnabled = [.copyPath, .favoriteDirectories].contains(settings.menuConfiguration.modules[i].moduleID)
        }
        let state = FinderMenuRuntimeState(snapshot: .make(settings: settings))
        let icons = FinderMenuIcons(loader: { _ in nil })
        let cases: [(selection: [URL], directory: URL?, expectedDirectory: String?)] = [
            ([], root, root.path), ([folder], root, folder.path), ([file], root, root.path),
            ([file, folder], root, nil), ([file], nil, root.path), ([], nil, nil)
        ]
        for value in cases {
            let context = FinderMenuBuildContext(menuKind: .toolbarItemMenu, selectedURLs: value.selection, targetedURL: value.directory)
            let target = FinderContextCollector.makeActionTarget(
                selectedPaths: value.selection.map(\.path), targetedPath: value.directory?.path,
                menuKind: .toolbarItemMenu, targetKind: context.targetContext.kind
            )
            #expect(target.sourcePaths == value.selection.map(\.path))
            #expect(target.currentDirectoryPath == value.expectedDirectory)
            #expect(!target.needsHostTargetResolution)
            let menu = try #require(FinderMenuRenderer.buildMenu(state: state, icons: icons, context: context, actionTarget: target))
            #expect(menu.items.contains { $0.title == FinderMenuModuleID.favoriteDirectories.defaultTitle })
            let copyItem = menu.items.first { $0.title == FinderMenuModuleID.copyPath.defaultTitle }
            if value.selection.isEmpty && value.directory == nil {
                #expect(copyItem == nil, "拿不到目标时不能展示文件操作或沿用上次工具栏目标")
                #expect(!context.canUseCurrentDirectoryTarget)
            } else {
                let item = try #require(copyItem)
                let action = try #require(FinderMenuActionRegistry.registration(forTag: item.tag))
                #expect(action.target == target)
                let request = try #require(try FinderCommandRequestFactory.makeRequest(descriptor: action.descriptor, target: action.target, settings: settings))
                let expected = value.selection.isEmpty ? value.directory!.path : value.selection.map(\.path).joined(separator: "\n")
                #expect(try FinderClipboardCommandExecutor().execute(request, targets: FinderCommandTargets())?.clipboardText == expected)
            }
        }
    }

    @Test("iCloud 单独注册且不放开 Library，空白处动作保持原始云盘目录")
    func iCloudDirectoryScopeAndTargets() throws {
        let fileManager = FileManager.default
        // 仅在临时目录模拟云盘结构，不读取或修改真实 iCloud 文件。
        let home = URL(fileURLWithPath: "/tmp/ArcKit-iCloud-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        let cloud = FinderObservedDirectoryBuilder.iCloudDriveDirectory(userHomeDirectory: home)
        #expect(FinderObservedDirectoryBuilder.defaultObservedDirectoryPaths(userHomeDirectory: home) == [home.path])
        let directory = cloud.appendingPathComponent("中文 工作目录", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = Set([home.path, cloud.path])
        #expect(Set(FinderObservedDirectoryBuilder.defaultObservedDirectoryPaths(userHomeDirectory: home)) == expected)
        for paths in [[home.path, cloud.path, directory.path], [directory.path, cloud.path, home.path]] {
            #expect(Set(FinderObservedDirectoryBuilder.sanitizedObservedDirectoryPaths(paths, userHomeDirectory: home)) == expected)
        }
        for suffix in ["Library", "Library/Mobile Documents", "Library/Mobile Documents/com~apple~CloudDocs-other",
                       "Library/Containers", "Library/Mobile Documents/com~apple~CloudDocs/../private"] {
            #expect(!FinderObservedDirectoryBuilder.isSafeObservedDirectoryPath(home.appendingPathComponent(suffix).path, userHomeDirectory: home))
        }

        // IPC 解码和最终 directoryURLs 转换也必须保留独立云盘根，且不依赖沙盒 stat。
        let accountHome = FinderUserHomeDirectoryResolver.resolve()
        let accountCloud = FinderObservedDirectoryBuilder.iCloudDriveDirectory(userHomeDirectory: accountHome)
        let snapshot = FinderExtensionSnapshot(observedDirectoryPaths: [accountHome.path, accountCloud.path])
        let decoded = try JSONDecoder().decode(FinderExtensionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(Set(FinderObservedDirectoryBuilder.urls(from: decoded.observedDirectoryPaths).map(\.path)) == Set([accountHome.path, accountCloud.path]))

        let target = FinderContextCollector.makeActionTarget(
            selectedPaths: [home.appendingPathComponent("陈旧选区").path], targetedPath: directory.path,
            menuKind: .contextualMenuForContainer
        )
        #expect(target.sourcePaths.isEmpty && target.currentDirectoryPath == directory.path)
        let settings = FinderRuntimeSettings.defaults
        let template = try #require(settings.menuConfiguration.fileTemplates.first { $0.normalizedExtension == "txt" })
        let create = FinderActionDescriptor(
            actionID: "arckit.newFile.\(template.id)", title: "新建文本", moduleID: .newFile,
            actionKind: .createNewFile, commandKind: .createNewFile, payload: .templateID(template.id),
            visibilityRule: .currentDirectoryTarget
        )
        let request = try #require(try FinderCommandRequestFactory.makeRequest(descriptor: create, target: target, settings: settings))
        let destination = try FinderCommandTargets().resolveTargetDirectory(for: request, actionName: "新建文件")
        let created = try NewFileCreationService().createFile(templateID: template.id, directoryPath: destination.path, settings: settings)
        #expect(created.fileURL.deletingLastPathComponent().path == directory.path)
        #expect(fileManager.fileExists(atPath: created.fileURL.path))
        #expect(try FinderCommandTargets.terminalDirectoryURL(for: created.fileURL).path == directory.path)
        let copy = FinderActionDescriptor(actionID: "arckit.copyPath", title: "复制路径", moduleID: .copyPath, actionKind: .copyPaths, commandKind: .copyPaths)
        let copyRequest = try #require(try FinderCommandRequestFactory.makeRequest(descriptor: copy, target: target, settings: settings))
        #expect(try FinderClipboardCommandExecutor().execute(copyRequest, targets: FinderCommandTargets())?.clipboardText == directory.path)
    }

    @MainActor
    @Test("Finder 彩色图标与模板软件图标经过菜单传输仍保留，终端只有一个入口")
    func menuIconsSurviveTransport() async throws {
        func solid(_ color: NSColor) throws -> Data {
            let source = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            return try #require(FinderMenuIcons.bitmapData(from: source))
        }
        let appPNG = try solid(.red)
        let templatePNG = try solid(.green)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); gate.signal() }
        let icons = FinderMenuIcons(loader: { key in
            _ = gate.wait(timeout: .now() + 5)
            switch key {
            case .application: return appPNG
            case .template: return templatePNG
            }
        })
        let app = FavoriteApplication(displayName: "测试应用", bundleIdentifier: "example.menu-icon", sortOrder: 0)
        var settings = FinderRuntimeSettings.defaults
        settings.menuConfiguration.favoriteApplications = [app]
        for index in settings.menuConfiguration.modules.indices {
            settings.menuConfiguration.modules[index].isEnabled = [.newFile, .favoriteApps, .copyPath].contains(settings.menuConfiguration.modules[index].moduleID)
        }
        var snapshot = FinderExtensionSnapshot.make(settings: settings)
        snapshot.fileTemplates = Array(snapshot.fileTemplates.filter { $0.template.normalizedExtension == "txt" }.prefix(1))
        let state = FinderMenuRuntimeState(snapshot: snapshot)
        icons.prepare(for: state.treeState)
        let context = FinderMenuBuildContext(hasSelection: true, selectedItemCount: 1, selectedFolderCount: 1)
        let target = FinderContextCollector.makeActionTarget(selectedPaths: ["/tmp/menu-icon"], targetedPath: "/tmp", targetKind: .folders)
        func menu() throws -> NSMenu {
            try #require(FinderMenuRenderer.buildMenu(state: state, icons: icons, context: context, actionTarget: target))
        }
        func leaves(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(leaves) ?? []) }.filter { !$0.isSeparatorItem }
        }
        func pixel(_ image: NSImage?) -> NSColor? {
            (image?.representations.first as? NSBitmapImageRep)?.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB)
        }
        func loaded(_ menu: NSMenu) -> Bool {
            let items = leaves(menu)
            return (pixel(items.first { $0.title == "测试应用" }?.image)?.redComponent ?? 0) > 0.9
                && (pixel(items.first { $0.title.hasSuffix("(.txt)") }?.image)?.greenComponent ?? 0) > 0.9
        }
        let initialMenu = try menu()
        let initial = leaves(initialMenu)
        #expect(initial.count == 5 && !loaded(initialMenu))
        #expect(initial.allSatisfy { $0.image?.isTemplate == false }, "加载中也使用彩色 Lucide，不能让 Finder 染回黑白")
        let fallbackPNGs = initial.compactMap { $0.image?.tiffRepresentation }
        for item in initial {
            let bitmap = try #require(item.image?.representations.first as? NSBitmapImageRep)
            let colors = (0..<32).flatMap { x in (0..<32).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) } }
            #expect(colors.contains { $0.alphaComponent > 0.8 && $0.blueComponent - $0.redComponent > 0.2 || $0.alphaComponent > 0.8 && $0.greenComponent - $0.redComponent > 0.2 })
        }
        gate.signal(); gate.signal()
        for _ in 0..<100 {
            if loaded(try menu()) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loaded(try menu()), "应用与模板分别读取后台缓存，不能一直显示 fallback")
        let data = try NSKeyedArchiver.archivedData(withRootObject: menu(), requiringSecureCoding: false)
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        decoder.requiresSecureCoding = false
        let restored = try #require(decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSMenu)
        decoder.finishDecoding()
        let items = leaves(restored)
        #expect(loaded(restored), "Finder 菜单传输后软件原色不能丢失")
        #expect(items.count == 5 && items.allSatisfy { $0.image?.size == NSSize(width: 16, height: 16) && $0.image?.isTemplate == false })
        for item in items {
            let bitmap = try #require(item.image?.representations.first as? NSBitmapImageRep)
            #expect(bitmap.pixelsWide == 32 && bitmap.pixelsHigh == 32)
        }
        let commands = items.filter { $0.action == NSSelectorFromString("performMenuAction:") }
        #expect(commands.count == 3)
        #expect(commands.allSatisfy { $0.tag > 0 && $0.representedObject == nil })
        var removed = state.treeState
        removed.favoriteApplications = []
        removed.fileTemplates = []
        icons.prepare(for: removed)
        #expect(leaves(try menu()).compactMap { $0.image?.tiffRepresentation } == fallbackPNGs, "移除资源后释放缓存，旧描述符只得到通用图标")

        var terminalState = state.treeState
        terminalState.modules = [.init(moduleID: .terminal, enabled: true, sortOrder: 0)]
        terminalState.availableTerminals = TerminalApp.allCases
        terminalState.defaultTerminal = try #require(TerminalApp.allCases.last)
        let entries = FinderMenuTreeBuilder.buildEntries(state: terminalState, context: context.targetContext)
        #expect(entries.count == 1, "默认终端和终端分组不得同时占据首层")
        guard case let .submenu(_, _, _, _, children)? = entries.first,
              case let .action(first)? = children.first,
              case let .terminal(payload) = first.payload else {
            Issue.record("终端应生成包含默认项的单一子菜单"); return
        }
        #expect(payload.terminalApp == terminalState.defaultTerminal)
        #expect(Set(children.map(\.id)).count == children.count)
        #expect(children.count == terminalState.availableTerminals.count * 2, "普通打开与应用支持的新建方式各一项")
        for child in children {
            guard case let .action(action) = child, case let .terminal(payload) = action.payload, payload.openMode != .open else { continue }
            #expect(payload.openMode == (payload.terminalApp == .terminal ? .window : .tab))
        }
    }

    @MainActor
    @Test("Finder 重建菜单项后仅靠 tag 找回同次目标，旧菜单不串到新菜单")
    func finderCallbackKeepsTarget() throws {
        var settings = FinderRuntimeSettings.defaults
        settings.menuConfiguration.fileTemplates = []
        settings.menuConfiguration.favoriteApplications = []
        for index in settings.menuConfiguration.modules.indices {
            settings.menuConfiguration.modules[index].isEnabled = settings.menuConfiguration.modules[index].moduleID == .copyPath
        }
        let state = FinderMenuRuntimeState(snapshot: .make(settings: settings))
        let icons = FinderMenuIcons(loader: { _ in nil })
        let context = FinderMenuBuildContext(hasSelection: true, selectedItemCount: 1, selectedFileCount: 1)
        func item(path: String) throws -> NSMenuItem {
            let target = FinderContextCollector.makeActionTarget(selectedPaths: [path], targetedPath: "/tmp", targetKind: .files)
            return try #require(FinderMenuRenderer.buildMenu(state: state, icons: icons, context: context, actionTarget: target)?.items.first)
        }
        let first = try item(path: "/tmp/window-a.txt")
        let second = try item(path: "/tmp/window-b.txt")
        #expect(first.tag != second.tag && first.title == second.title)
        // 模拟 Finder 的桥接，不使用本地 NSKeyedArchiver 假定字段会原样保留。
        let callback = NSMenuItem(title: first.title, action: first.action, keyEquivalent: "")
        callback.tag = first.tag
        callback.identifier = NSUserInterfaceItemIdentifier("performMenuAction:")
        callback.representedObject = nil
        let firstAction = try #require(FinderMenuActionRegistry.registration(forTag: callback.tag))
        #expect(firstAction.target.sourcePaths == ["/tmp/window-a.txt"])
        callback.tag = second.tag
        #expect(FinderMenuActionRegistry.registration(forTag: callback.tag)?.target.sourcePaths == ["/tmp/window-b.txt"])
        callback.tag = 0
        #expect(FinderMenuActionRegistry.registration(forTag: callback.tag) == nil)
        for _ in 0..<FinderMenuActionRegistry.maxEntries {
            _ = FinderMenuActionRegistry.register(firstAction.descriptor, target: firstAction.target)
        }
        callback.tag = first.tag
        #expect(FinderMenuActionRegistry.registration(forTag: callback.tag) == nil, "被淘汰的菜单不能重新绑定其他目标")
    }

    @Test("打开应用等待系统回执，异步失败和未回应不能提前报成功")
    func applicationOpenWaitsForReply() throws {
        let urls = [URL(fileURLWithPath: "/tmp/open-reply.txt")]
        let delayedFailure = FinderApplicationOpener(open: { _, _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion("目标应用拒绝打开") }
        })
        #expect(throws: (any Error).self) { try delayedFailure.openURLs(urls, applicationURL: nil, label: "测试") }
        let absentReply = FinderApplicationOpener(timeout: 0.02, open: { _, _, _ in })
        #expect(throws: (any Error).self) { try absentReply.openURLs(urls, applicationURL: nil, label: "测试") }
        let success = FinderApplicationOpener(open: { _, _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion(nil) }
        })
        try success.openURLs(urls, applicationURL: nil, label: "测试")
    }

    @Test("复制移动失败时整批回滚，保留唯一副本")
    func fileTransferRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKitTransferRollback-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let copyDestination = root.appendingPathComponent("CopyDestination", isDirectory: true)
        let moveDestination = root.appendingPathComponent("MoveDestination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copyDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moveDestination, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("First.txt")
        let second = source.appendingPathComponent("Second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }

        let copyPlan = try FinderFileTransferPlanner().makePlan(
            sourcePaths: [first.path, second.path],
            destinationDirectoryPath: copyDestination.path,
            mode: .copy
        )
        var copyCount = 0
        do {
            _ = try FinderFileTransferExecutor(copyItem: { sourceURL, destinationURL in
                copyCount += 1
                if copyCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }).execute(copyPlan)
            Issue.record("复制批次中途失败必须抛错")
        } catch is FinderFileTransferError {
            // 预期的执行失败。
        }
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path), "复制回滚后全部来源必须保留")
        let copyDestinationContents = try FileManager.default.contentsOfDirectory(atPath: copyDestination.path)
        #expect(copyDestinationContents.isEmpty, "复制回滚后不得残留部分目标")

        let movePlan = try FinderFileTransferPlanner().makePlan(
            sourcePaths: [first.path, second.path],
            destinationDirectoryPath: moveDestination.path,
            mode: .move
        )
        var forwardMoveCount = 0
        do {
            _ = try FinderFileTransferExecutor(moveItem: { sourceURL, destinationURL in
                if sourceURL.deletingLastPathComponent() == source {
                    forwardMoveCount += 1
                    if forwardMoveCount == 2 { throw CocoaError(.fileWriteNoPermission) }
                }
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            }).execute(movePlan)
            Issue.record("移动批次中途失败必须抛错")
        } catch is FinderFileTransferError {
            // 预期的执行失败。
        }
        #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path), "移动回滚后全部来源必须恢复")
        let moveDestinationContents = try FileManager.default.contentsOfDirectory(atPath: moveDestination.path)
        #expect(moveDestinationContents.isEmpty, "移动回滚后不得残留部分目标")

        // 已复制成功但源文件被并发移除时，回滚不能再删除唯一剩余副本。
        let missingSourcePlan = try FinderFileTransferPlanner().makePlan(
            sourcePaths: [first.path], destinationDirectoryPath: copyDestination.path, mode: .copy
        )
        do {
            _ = try FinderFileTransferExecutor(copyItem: { sourceURL, destinationURL in
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try FileManager.default.removeItem(at: sourceURL)
            }).execute(missingSourcePlan)
            Issue.record("源项目丢失必须报告无法完整恢复")
        } catch let error as FinderFileTransferError {
            guard case .rollbackFailed = error else { throw error }
        }
        let preservedCopy = copyDestination.appendingPathComponent(first.lastPathComponent)
        #expect(try Data(contentsOf: preservedCopy) == Data("first".utf8), "不能删除唯一剩余副本")
        try FileManager.default.moveItem(at: preservedCopy, to: first)

        // 系统写入后才抛错时，不把未返回成功的步骤误判为完全无副作用。
        let uncertainMove = try FinderFileTransferPlanner().makePlan(
            sourcePaths: [first.path], destinationDirectoryPath: moveDestination.path, mode: .move
        )
        do {
            _ = try FinderFileTransferExecutor(moveItem: { sourceURL, destinationURL in
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                throw CocoaError(.fileWriteUnknown)
            }).execute(uncertainMove)
            Issue.record("失败步骤产生文件变化时必须报告待检查位置")
        } catch let error as FinderFileTransferError {
            guard case .rollbackFailed(_, _, let details) = error else { throw error }
            #expect(details.contains(first.path) && details.contains(moveDestination.path), "不确定结果必须包含来源与目标位置")
        }
        #expect(try Data(contentsOf: moveDestination.appendingPathComponent(first.lastPathComponent)) == Data("first".utf8), "不确定步骤保留现场，不能盲目删除")
    }

    @Test("批量重命名失败时恢复原名称并清理暂存")
    func batchRenameRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKitBatchRenameExecute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let plan = try FinderBatchRenamePlanner().makePlan(
            sourcePaths: [first.path, second.path],
            rule: .init(mode: .prefix, primaryText: "done-")
        )

        let failure = BatchRenameMoveFailureController(failAtCall: 4)
        do {
            _ = try FinderBatchRenameExecutor(moveItem: failure.move).execute(plan)
            Issue.record("第二阶段失败时必须抛错")
        } catch let error as FinderBatchRenameError {
            guard case .executionFailed = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: first.path), "失败回滚后第一个原文件必须恢复")
        #expect(FileManager.default.fileExists(atPath: second.path), "失败回滚后第二个原文件必须恢复")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("done-first.txt").path), "失败后不能残留部分目标名称")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("done-second.txt").path), "失败后不能残留部分目标名称")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".arckit-rename-") }
        #expect(leftovers.isEmpty, "失败回滚后不能残留内部临时文件")

        let receipt = try FinderBatchRenameExecutor().execute(plan)
        #expect(receipt.destinationURLs.map(\.lastPathComponent).sorted() == ["done-first.txt", "done-second.txt"], "成功执行必须返回全部目标路径")
        #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path), "成功后原名称必须消失")
    }

    @MainActor
    @Test("Finder 接收记录跨 Host 实例防重放，过期请求拒绝执行")
    func finderAdmissionSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("accepted.json")
        let sessionID = UUID()
        let now = Date()
        let request = FinderCommandRequest(payload: .copyPaths(FinderPathPayload(sourcePaths: ["/tmp/example"])), createdAt: now)
        try FinderCommandAdmissionStore(sessionID: sessionID, fileURL: url).accept(request, now: now)
        let restarted = FinderCommandAdmissionStore(sessionID: sessionID, fileURL: url)
        #expect(throws: (any Error).self) { try restarted.accept(request, now: now) }
        let expired = FinderCommandRequest(payload: request.payload, createdAt: now.addingTimeInterval(-31))
        #expect(throws: (any Error).self) { try restarted.accept(expired, now: now) }
        let fresh = FinderCommandRequest(payload: request.payload, createdAt: now)
        try restarted.accept(fresh, now: now)
    }

    @Test("Finder Worker 拒绝并发且失败后释放名额")
    @MainActor
    func workerAdmissionAndRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker")
        // 仅在临时目录运行无副作用的替身，不启动 Finder、面板或已安装 Agent。
        try Data("#!/bin/sh\nexec /bin/sleep 0.2\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let request = FinderCommandRequest(payload: .copyPaths(FinderPathPayload(sourcePaths: ["/tmp/worker.txt"])))
        let firstClient = FinderOperationWorkerClient(executableURL: executable, timeout: 2)
        let secondClient = FinderOperationWorkerClient(executableURL: executable, timeout: 2)
        let first: Result<FinderCommandExecutionResult?, FinderOperationWorkerError> = await withCheckedContinuation { continuation in
            firstClient.execute(request, settings: .defaults) { continuation.resume(returning: $0) }
            secondClient.execute(request, settings: .defaults) { result in
                #expect(result == .failure(.busy))
            }
        }
        #expect(first == .failure(.malformedReply))
        // 替身退出后，短暂孙进程仍持有输出管道；客户端必须超时回收读取任务并释放名额。
        try Data("#!/bin/sh\n/bin/sleep 3 &\nexit 0\n".utf8).write(to: executable)
        let inheritedPipe: Result<FinderCommandExecutionResult?, FinderOperationWorkerError> = await withCheckedContinuation { continuation in
            firstClient.execute(request, settings: .defaults) { continuation.resume(returning: $0) }
        }
        #expect(inheritedPipe == .failure(.outputDidNotClose))
        try Data("#!/bin/sh\nexec /bin/sleep 0.2\n".utf8).write(to: executable)
        let next: Result<FinderCommandExecutionResult?, FinderOperationWorkerError> = await withCheckedContinuation { continuation in
            secondClient.execute(request, settings: .defaults) { continuation.resume(returning: $0) }
        }
        #expect(next == .failure(.malformedReply))
    }
}

private final class BatchRenameMoveFailureController: @unchecked Sendable {
    private let lock = NSLock()
    private let failAtCall: Int
    private var callCount = 0

    init(failAtCall: Int) {
        self.failAtCall = failAtCall
    }

    func move(_ source: URL, _ destination: URL) throws {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failAtCall
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}


extension FinderTests {
    @Test("终端自动化拒绝与执行失败分开，Terminal 不再向现有标签写入命令")
    func terminalAutomationBoundaries() throws {
        let directory = URL(fileURLWithPath: "/tmp/quote' \" $() 中文")
        var executions = 0
        let denied = FinderTerminalAutomation { _ in
            executions += 1
            throw NSError(domain: "ArcKit.AppleScript", code: -1743)
        }
        do {
            try denied.execute(directory: directory, terminal: .terminal, mode: .window)
            Issue.record("拒绝自动化不能报告成功")
        } catch {
            #expect(error.localizedDescription == FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.terminalAuthorizationDenied("Terminal"))).localizedDescription)
            #expect(error.localizedDescription.contains("Terminal"))
        }
        #expect(executions == 1)
        #expect(throws: (any Error).self) {
            try denied.execute(directory: directory, terminal: .terminal, mode: .tab)
        }
        #expect(executions == 1, "不支持的方式在执行前拒绝，不发送额外授权或输入")
        let failure = FinderTerminalAutomation { _ in
            throw NSError(domain: "ArcKit.AppleScript", code: -1728, userInfo: [NSLocalizedDescriptionKey: "窗口不存在"])
        }
        do {
            try failure.execute(directory: directory, terminal: .iTerm, mode: .tab)
            Issue.record("操作失败不能报告成功")
        } catch { #expect(error.localizedDescription == "窗口不存在") }
    }
}
