#if DEBUG
import ArcKitPlatform
import ArcKitPersistence
import ArcKitFinder
import AppKit
import Combine
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 在 StorageBootstrap 之前分流；不读取生产数据库、不注册 Host。
@MainActor
public enum MenuBarDevelopmentSession {
    public static func handle(arguments: [String]) -> Int32? {
        if arguments.contains("--menu-bar-combined-entry-check") {
            guard arguments.count == 3, arguments[1] == "--menu-bar-combined-entry-check" else { return 2 }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory); app.finishLaunching()
            do {
                let check = try MenuBarCombinedEntryCheck(directory: URL(fileURLWithPath: arguments[2]))
                app.activate(ignoringOtherApps: true)
                withExtendedLifetime(check) { app.run() }
                return 0
            } catch { print(error.localizedDescription); return 1 }
        }
        if arguments.contains("--menu-bar-arrangement-read") {
            guard arguments.count == 3, arguments[1] == "--menu-bar-arrangement-read" else { return 2 }
            let directory = URL(fileURLWithPath: arguments[2])
            guard !FileManager.default.fileExists(atPath: directory.path) else { return 2 }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited); app.finishLaunching()
            Task { @MainActor in
                do {
                    let paths = ArcKitStoragePaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".arc-kit"))
                    let repository = SettingsRepository(database: ArcKitDatabase(reading: paths))
                    let selected = try await Task.detached { try repository.load().menuBar.collectedApplications }.value
                    let access = MenuBarCollectionAccess(read: { selected }, write: { _, _ in throw MenuBarArrangementError.unavailable })
                    let model = MenuBarArrangementModel(collection: access, owner: "com.archalo.arckit")
                    model.refresh(collectionEnabled: true)
                    await model.finish()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let report: [String: Any] = ["error": model.error ?? "", "items": model.items.map {
                        ["title": $0.observed.displayTitle, "editable": $0.isEditable, "key": $0.id] as [String: Any]
                    }]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("report.json"))
                    Darwin.exit(model.error == nil ? 0 : 3)
                } catch { print(error.localizedDescription); Darwin.exit(1) }
            }
            app.run(); return 0
        }
        if arguments.contains("--menu-bar-visibility-check") {
            guard arguments.count == 4, arguments[1] == "--menu-bar-visibility-check",
                  arguments[3].hasPrefix("com.archalo.arckit.visibility-probe.") else { return 2 }
            let directory = URL(fileURLWithPath: arguments[2]), target = arguments[3]
            guard !FileManager.default.fileExists(atPath: directory.path) else { return 2 }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited); app.finishLaunching()
            Task {
                let session = MenuBarVisibilitySession()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try session.conceal(collectedApplications: [target], owner: "check")
                    try Data().write(to: directory.appendingPathComponent("hidden"))
                    let start = Date()
                    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("reveal").path) {
                        if Date().timeIntervalSince(start) > 45 { throw CancellationError() }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try session.reveal()
                    try Data().write(to: directory.appendingPathComponent("restored"))
                    Darwin.exit(0)
                } catch {
                    try? session.reveal(); print(error.localizedDescription); Darwin.exit(1)
                }
            }
            app.run(); return 0
        }
        if arguments.contains("--menu-bar-capture") {
            guard arguments.count == 3, arguments[1] == "--menu-bar-capture" else { return 2 }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited); application.finishLaunching()
            let check = MenuBarNativeCheck(directory: URL(fileURLWithPath: arguments[2]), captureOnly: true)
            Task { Darwin.exit(await check.run()) }
            application.run(); return 0
        }
        if arguments.contains("--menu-bar-native-check") || arguments.contains("--menu-bar-width-check") || arguments.contains("--menu-bar-installed-fixture") || arguments.contains("--menu-bar-order-check") {
            guard arguments.count == 3, ["--menu-bar-native-check", "--menu-bar-width-check", "--menu-bar-installed-fixture", "--menu-bar-order-check"].contains(arguments[1]) else {
                print("Usage: ArcKitApp (--menu-bar-native-check | --menu-bar-width-check | --menu-bar-installed-fixture | --menu-bar-order-check) <new-directory>"); return 2
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let check = MenuBarNativeCheck(directory: URL(fileURLWithPath: arguments[2]), measuresWidths: arguments[1] == "--menu-bar-width-check", fixtureOnly: arguments[1] == "--menu-bar-installed-fixture", orderOnly: arguments[1] == "--menu-bar-order-check")
            Task { Darwin.exit(await check.run()) }
            application.run()
            return 0
        }
        if let index = arguments.firstIndex(where: { ["--menu-bar-render", "--menu-bar-preferences-render", "--menu-bar-arrangement-render", "--menu-bar-entry-render"].contains($0) }) {
            guard index == 1, arguments.count == 3 else { print(L10n.string(.MenuBar.probeUsage)); return 2 }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            let directory = URL(fileURLWithPath: arguments[2])
            Task {
                let result: Int32
                switch arguments[index] {
                case "--menu-bar-entry-render": result = await exportEntry(to: directory)
                case "--menu-bar-arrangement-render": result = await exportArrangement(to: directory)
                case "--menu-bar-preferences-render": result = await exportPreferences(to: directory)
                default: result = await exportSettings(to: directory)
                }
                Darwin.exit(result)
            }
            application.run()
            return 0
        }
        if let index = arguments.firstIndex(of: "--menu-bar-probe") {
            guard index == 1, arguments.count == 3 else {
                print(L10n.string(.MenuBar.probeUsage)); return 2
            }
            return export(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if arguments.contains("--menu-bar-settings"), arguments.contains("--ui-debug"), arguments.count == 3 { return nil }
        if arguments.contains(where: { $0.hasPrefix("--menu-bar-") }) { print(L10n.string(.MenuBar.probeUsage)); return 2 }
        return nil
    }

    private static func exportSettings(to directory: URL) async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let repository = SettingsRepository(directoryURL: directory.appendingPathComponent("data"))
            defer { try? repository.database.close() }
            let model = SettingsModel(store: repository,
                templateLibrary: NewFileTemplateLibrary(baseDirectory: directory.appendingPathComponent("data/templates")))
            await model.waitForPendingChanges()
            guard model.committedSettings != nil else { throw CocoaError(.fileReadCorruptFile) }
            let service = MenuBarManagementService(arrangementModel: MenuBarArrangementModel(collection: .preview(previewCollection()), isPreview: true), driverFactory: { WorkflowPreviewDriver() },
                hotKeyFactory: { WorkflowPreviewHotKeys() }, captureInventory: { access in
                    let inventory = previewInventory()
                    access.begin(id: inventory.id, displays: inventory.displays)
                    for item in inventory.items where item.supportsActivation {
                        access.add(.init(item: item, read: { _ in
                            .init(isMenuBarItem: true, actions: ["AXShowMenu", "AXPress"])
                        }, perform: { _ in 0 }))
                    }
                    return inventory
                },
                accessSessionFactory: { MenuBarItemAccessSession(isTrusted: { true }, process: { pid in
                    guard let item = previewInventory().items.first(where: { $0.processID == pid }), let launch = item.processLaunchDate else { return nil }
                    return .init(processID: pid, launchDate: launch, bundleIdentifier: item.bundleIdentifier)
                }, currentDisplays: { previewInventory().displays }) }, currentDisplayID: { 900 },
                shelfPanelFactory: { _, _ in WorkflowPreviewPanel() },
                idleTicks: { Empty().eraseToAnyPublisher() },
                workspaceNotifications: NotificationCenter(), applicationNotifications: NotificationCenter())
            let session = RuntimeSettingsSession(model: model) { _, current in service.apply(current.menuBar) }
            session.start()
            defer { session.stop(); service.stop() }
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    for width in [CGFloat(780), CGFloat(480)] {
                        try service.arrangementModel.load(previewInventory(), positions: previewPositions())
                        model.menuBarEditor.update { $0.isEnabled = false; $0.collectedApplications = previewCollection() }
                        guard await model.finishPendingChanges() else { throw CocoaError(.fileWriteUnknown) }
                        let workflow = MenuBarWorkflow(editor: model.menuBarEditor, service: service)
                        let owner = UUID()
                        service.beginManagement(owner: owner)
                        await service.finishItemRequest()
                        let suffix = "\(Int(width))-\(scheme == .light ? "light" : "dark")-\(language.rawValue)"
                        let size = CGSize(width: width, height: 600)
                        let view = MenuBarSection(model: model.menuBarEditor, service: service, workflow: workflow, ownerID: owner, usesSampleData: true)
                            .searchPreview()
                            .frame(width: width, height: size.height).environment(\.colorScheme, scheme).environment(\.locale, L10n.locale)
                            .environment(\.controlActiveState, .active)
                            // 离屏只导出稳定状态，避免把原生开关的过渡帧当成最终结果。
                            .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                        window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
                        // 同一视图内执行真实按钮处理流程，避免销毁上一张视图干扰下一步操作。
                        func page(_ state: String) async throws {
                            host.layoutSubtreeIfNeeded()
                            // 隐藏窗口不会自动完成首次绘制；给 SwiftUI 更新与原生控件重绘留出一轮处理时间。
                            host.displayIfNeeded()
                            try await Task.sleep(for: .milliseconds(350))
                            host.layoutSubtreeIfNeeded()
                            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            func switchStates(_ view: NSView) -> [Int] {
                                (view as? NSSwitch).map { [$0.state.rawValue] } ?? view.subviews.flatMap(switchStates)
                            }
                            let expectedSwitch = model.menuBarEditor.committedSettings?.isEnabled == true ? 1 : 0
                            guard switchStates(host) == [expectedSwitch] else { throw CocoaError(.validationMissingMandatoryProperty) }
                            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                            try data.write(to: directory.appendingPathComponent("\(state)-\(suffix).png"))
                        }
                        do {
                            try await page("01-start")
                            await workflow.setEnabled(true)
                            try await page("02-enabled")
                            workflow.toggle()
                            await service.finishPresentation()
                            try await page("03-hidden")
                            workflow.toggle()
                            await service.finishPresentation()
                            try await page("04-visible")
                            // 设置页与原生按钮共用同一个切换入口，不再有单独的整理阶段。
                            service.toggleCollection()
                            await service.finishPresentation()
                            try await page("05-native-button")
                            guard service.requestedPresentation == .collapsed else { throw CocoaError(.validationMissingMandatoryProperty) }
                            await workflow.setEnabled(false)
                            try await page("06-disabled")
                            if width == 480 && scheme == .light {
                                service.refreshManagement(owner: owner)
                                await service.finishItemRequest()
                                service.managementModel.query = "Tail"
                                try await page("management-search")
                                service.managementModel.query = ""
                                guard let item = service.managementModel.items.first(where: \.supportsActivation) else { throw CocoaError(.validationMissingMandatoryProperty) }
                                service.activateManagementItem(item.id, owner: owner)
                                await service.finishItemRequest()
                                guard case .sent? = service.managementModel.outcomes[item.id] else { throw CocoaError(.validationMissingMandatoryProperty) }
                                try await page("management-sent")
                                service.environmentDidChange(.layout)
                                try await page("management-stale")
                                service.managementModel.fail(L10n.string(.MenuBar.settingsMainPermission), permissionRequired: true)
                                try await page("management-permission")
                                service.managementModel.begin(clearQuery: true)
                                try await page("management-loading")
                                let inventory = previewInventory()
                                service.managementModel.load(.init(id: UUID(), capturedAt: Date(), systemVersion: "Preview", accessibility: .granted,
                                    displays: inventory.displays, items: [], issues: []))
                                try await page("management-empty")
                                service.refreshManagement(owner: owner)
                                await service.finishItemRequest()
                                service.managementModel.query = "not-a-menu-bar-item"
                                try await page("management-no-matches")
                            }
                            service.endManagement(owner: owner)
                            window.close()
                        } catch { window.close(); throw error }
                    }
                }
            }
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    try await writeEntryPanel(scheme: scheme,
                        to: directory.appendingPathComponent("entry-panel-\(scheme == .light ? "light" : "dark")-\(language.rawValue).png"))
                }
            }
            try await writePreferencesImages(model: model, service: service, directory: directory)
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    let shelf = MenuBarShelfModel()
                    shelf.supportsCollectedScope = MenuBarPartitionMode.current.supportsSections
                    let inventory = previewInventory()
                    shelf.load(inventory, partition: try shelfPreviewPartition(inventory), targetDisplayID: 900)
                    let view = MenuBarShelfView(model: shelf, refresh: {}, close: {}, isPreview: true)
                        .frame(width: 540, height: 400).environment(\.colorScheme, scheme).environment(\.locale, L10n.locale)
                    try await writeSettingsImage(view, size: CGSize(width: 540, height: 400), scheme: scheme,
                        to: directory.appendingPathComponent("shelf-\(scheme == .light ? "light" : "dark")-\(language.rawValue).png"))
                    let collection = MenuBarShelfModel()
                    collection.scope = .collected
                    collection.load(inventory, partition: try shelfPreviewPartition(inventory), targetDisplayID: 900)
                    let collectionSize = CGSize(width: 540, height: collection.preferredHeight)
                    let collectionView = MenuBarShelfView(model: collection, refresh: {}, close: {}, isPreview: true)
                        .frame(width: collectionSize.width, height: collectionSize.height).environment(\.colorScheme, scheme).environment(\.locale, L10n.locale)
                    try await writeSettingsImage(collectionView, size: collectionSize, scheme: scheme,
                        to: directory.appendingPathComponent("collection-\(scheme == .light ? "light" : "dark")-\(language.rawValue).png"))
                }
            }
            L10n.configure(.simplifiedChinese)
            for state in ["loading", "empty", "permission", "unconfirmed", "collection-unavailable", "collection-ambiguous"] {
                let shelf = MenuBarShelfModel()
                if state == "loading" { shelf.begin(clearQuery: true) }
                else if state == "permission" { shelf.fail(L10n.string(.MenuBar.settingsMainPermission), permissionRequired: true) }
                else if state == "unconfirmed" {
                    shelf.load(previewInventory())
                    shelf.feedback = MenuBarItemAccessError.requestUnconfirmed(-25204).localizedDescription
                }
                else if state == "collection-unavailable" {
                    shelf.scope = .collected; shelf.load(previewInventory())
                } else if state == "collection-ambiguous" {
                    shelf.scope = .collected
                    let inventory = previewInventory(includingUnknown: true)
                    shelf.load(inventory, partition: try shelfPreviewPartition(inventory), targetDisplayID: 900)
                }
                let size = CGSize(width: 540, height: shelf.preferredHeight)
                let view = MenuBarShelfView(model: shelf, refresh: {}, close: {}, openPermission: {}, showAll: {}, isPreview: true)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, .light).environment(\.locale, L10n.locale)
                try await writeSettingsImage(view, size: size, scheme: .light,
                    to: directory.appendingPathComponent("shelf-\(state).png"))
            }
            let imageCount = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }.count
            print("MENU_BAR_SETTINGS_RENDER path=\(directory.path) images=\(imageCount) runtime=preview")
            return 0
        } catch {
            print(L10n.string(.MenuBar.probeFailure(error.localizedDescription)))
            return 1
        }
    }

    private static func exportPreferences(to directory: URL) async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let repository = SettingsRepository(directoryURL: directory.appendingPathComponent("data"))
            defer { try? repository.database.close() }
            let model = SettingsModel(store: repository,
                templateLibrary: NewFileTemplateLibrary(baseDirectory: directory.appendingPathComponent("data/templates")))
            await model.waitForPendingChanges()
            let service = MenuBarManagementService(isPreview: true)
            try await writePreferencesImages(model: model, service: service, directory: directory)
            print("MENU_BAR_PREFERENCES_RENDER path=\(directory.path) images=8 runtime=preview")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }

    private static func writePreferencesImages(model: SettingsModel, service: MenuBarManagementService, directory: URL) async throws {
        for language in [ArcKitLanguage.simplifiedChinese, .english] {
            L10n.configure(language)
            for scheme in [ColorScheme.light, .dark] {
                for enabled in [true, false] {
                    model.menuBarEditor.update {
                        $0.autoCollapseEnabled = enabled
                        $0.autoCollapseDelayMinutes = enabled ? 5 : 12
                    }
                    guard await model.finishPendingChanges() else { throw CocoaError(.fileWriteUnknown) }
                    let view = MenuBarPreferencesSheet(model: model.menuBarEditor, service: service)
                        .environment(\.locale, L10n.locale).environment(\.controlActiveState, .active)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    let size = NSHostingView(rootView: view).fittingSize
                    let suffix = enabled && scheme == .light ? language.rawValue : "\(enabled ? "on" : "off")-\(scheme == .light ? "light" : "dark")-\(language.rawValue)"
                    try await writeSettingsImage(view, size: size, scheme: scheme,
                        to: directory.appendingPathComponent("07-settings-\(suffix).png"))
                }
            }
        }
    }

    static func previewInventory(includingUnknown: Bool = false) -> MenuBarInventory {
        let display = MenuBarDisplay(id: 900, name: "Preview", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: nil, scale: 2)
        let samples: [(String, String, String, Bool)] = [
            ("Docker", "com.docker.docker", L10n.string(.MenuBar.previewDocker), true),
            ("Raycast", "com.raycast.macos", L10n.string(.MenuBar.previewRaycast), true),
            ("Tailscale", "io.tailscale.ipn.macos", L10n.string(.MenuBar.previewTailscale), true),
            (L10n.string(.MenuBar.previewChatName), "com.tencent.xinWeChat", L10n.string(.MenuBar.previewChat), true),
            ("OneDrive", "com.microsoft.OneDrive", L10n.string(.MenuBar.previewCloud), true),
            ("MenuBarAgent", "com.apple.MenuBarAgent", L10n.string(.MenuBar.previewClock), false)
        ] + (includingUnknown ? [("Unclassified", "preview.unknown", "", false)] : [])
        let positions: [CGFloat] = [1000, 1040, 800, 840, 1200, 1240, 1090]
        let items = samples.enumerated().map { index, sample in
            MenuBarObservedItem(id: UUID(), processID: Int32(900001 + index), processLaunchDate: Date(timeIntervalSince1970: 100),
                bundleIdentifier: sample.1, applicationName: sample.0, accessibilityIdentifier: nil,
                frame: CGRect(x: positions[index], y: 4, width: 22, height: 22), displayID: display.id,
                declaresPress: sample.3, declaresShowMenu: sample.3 && index != 4, positionSettable: false, label: sample.2)
        }
        return .init(id: UUID(), capturedAt: Date(), systemVersion: "Preview", accessibility: .granted, displays: [display], items: items, issues: [])
    }

    static func previewCollection() -> Set<String> {
        Set(previewInventory().items.enumerated().filter { [0, 2].contains($0.offset) }.compactMap { $0.element.bundleIdentifier })
    }

    static func previewPositions() -> [String: Double] {
        var positions = ["status:preview::menu-bar.group-v3.toggle": 500.0, "status:preview::menu-bar.group-v3.hidden": 534.0]
        let values = [650.0, 200, 700, 300, 100]
        for (index, item) in previewInventory().items.prefix(5).enumerated() {
            positions["status:\(item.bundleIdentifier!)::Item-0"] = values[index]
        }
        return positions
    }

    private static func exportArrangement(to directory: URL) async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let repository = SettingsRepository(directoryURL: directory.appendingPathComponent("data"))
            defer { try? repository.database.close() }
            let model = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: directory.appendingPathComponent("data/templates")))
            await model.waitForPendingChanges()
            model.menuBarEditor.update { $0.isEnabled = true; $0.collectedApplications = previewCollection() }
            guard await model.finishPendingChanges() else { throw CocoaError(.fileWriteUnknown) }
            let service = MenuBarManagementService(isPreview: true, collectionAccess: .preview(previewCollection()))
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    for width in [CGFloat(780), CGFloat(480)] {
                        try service.arrangementModel.load(previewInventory(), positions: previewPositions())
                        let suffix = "\(Int(width))-\(scheme == .light ? "light" : "dark")-\(language.rawValue)"
                        let view = MenuBarSection(model: model.menuBarEditor, service: service, usesSampleData: true)
                            .environment(\.locale, L10n.locale).frame(width: width, height: 650)
                            .environment(\.controlActiveState, .active)
                            .transaction { $0.animation = nil; $0.disablesAnimations = true }
                        try await writeSettingsImage(view, size: CGSize(width: width, height: 650), scheme: scheme,
                            to: directory.appendingPathComponent("arrange-\(suffix).png"))
                        let id = "status:com.tencent.xinWeChat::Item-0"
                        service.arrangementModel.move(id, to: .collected)
                        try await writeSettingsImage(view, size: CGSize(width: width, height: 650), scheme: scheme,
                            to: directory.appendingPathComponent("draft-\(suffix).png"))
                        model.menuBarEditor.update { $0.collectedApplications = [] }
                        guard await model.finishPendingChanges() else { throw CocoaError(.fileWriteUnknown) }
                        let restricted = MenuBarArrangementModel(collection: .preview(), isPreview: true,
                            readCollectionRestrictions: { bundles in
                                ["com.raycast.macos": MenuBarCollectionRestriction.linkedApplications, "com.microsoft.OneDrive": .unavailable]
                                    .filter { bundles.contains($0.key) }
                            })
                        var restrictedPositions = previewPositions()
                        restrictedPositions["status:com.raycast.macos::Item-0"] = 900
                        restrictedPositions["status:com.microsoft.OneDrive::Item-0"] = 800
                        try restricted.load(previewInventory(), positions: restrictedPositions)
                        let emptyService = MenuBarManagementService(isPreview: true, partitionMode: .systemVisibility, arrangementModel: restricted)
                        let emptyView = MenuBarSection(model: model.menuBarEditor, service: emptyService, usesSampleData: true)
                            .environment(\.locale, L10n.locale).frame(width: width, height: 650)
                            .environment(\.controlActiveState, .active)
                        try await writeSettingsImage(emptyView, size: CGSize(width: width, height: 650), scheme: scheme,
                            to: directory.appendingPathComponent("empty-restricted-\(suffix).png"))
                        model.menuBarEditor.update { $0.collectedApplications = previewCollection() }
                        guard await model.finishPendingChanges() else { throw CocoaError(.fileWriteUnknown) }
                    }
                }
            }
            print("MENU_BAR_ARRANGEMENT_RENDER path=\(directory.path) images=24 runtime=preview")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }

    private static func shelfPreviewPartition(_ inventory: MenuBarInventory) throws -> MenuBarPartitionSnapshot {
        try .init(generation: 1, displays: inventory.displays, control: CGRect(x: 1300, y: 4, width: 18, height: 22),
            hidden: CGRect(x: 1100, y: 4, width: 18, height: 22), deep: CGRect(x: 900, y: 4, width: 18, height: 22))
    }

    private static func writeEntryPanel(scheme: ColorScheme, to url: URL) async throws {
        let state = MenuBarPanelState()
        let actions = MenuBarPanelActions(performWindow: { _, _ in }, performScene: { _ in }, undoScene: { _ in },
            openScenes: {}, setWindowEnabled: { _ in }, setMouseEnabled: { _ in }, setFinderEnabled: { _ in },
            openSection: { _ in }, retrySave: {}, checkState: {}, quit: {})
        let view = MenuBarPanel(state: state, actions: actions).environment(\.controlActiveState, .active)
        let size = NSHostingView(rootView: view).fittingSize
        try await writeSettingsImage(view, size: size, scheme: scheme, to: url)
    }

    private static func exportEntry(to directory: URL) async -> Int32 {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    let suffix = "\(scheme == .light ? "light" : "dark")-\(language.rawValue)"
                    for enabled in [true, false] {
                        let button = NSButton()
                        let entry = MenuBarCombinedEntry(button: button, collapse: {}, reveal: {}, openMenu: {})
                        entry.update(collectionVisible: enabled, presentation: .collapsed, ready: true, busy: false, menuStatus: "Arc Kit")
                        if let image = button.image {
                            let view = Image(nsImage: image).frame(width: 58, height: 28)
                            try await writeSettingsImage(view, size: CGSize(width: 58, height: 28), scheme: scheme,
                                to: directory.appendingPathComponent("combined-\(enabled ? "on" : "off")-\(suffix).png"))
                        }
                    }
                    try await writeEntryPanel(scheme: scheme,
                        to: directory.appendingPathComponent("entry-panel-\(suffix).png"))
                }
            }
            try await writeIconArtworkPreview(to: directory.appendingPathComponent("menu-bar-icon-preview.png"))
            try writeIconAnimationPreview(to: directory)
            print("MENU_BAR_ENTRY_RENDER path=\(directory.path) images=13 animationKeyframes=5 gifs=1 runtime=preview")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }

    private static func writeIconArtworkPreview(to url: URL) async throws {
        let samples: [(String, Color, Color)] = [
            ("浅色", Color(red: 0.96, green: 0.96, blue: 0.95), .black),
            ("深色", Color(red: 0.10, green: 0.11, blue: 0.13), .white),
            ("橄榄色", Color(red: 0.31, green: 0.31, blue: 0.21), .white),
            ("蓝色", Color(red: 0.16, green: 0.35, blue: 0.65), .white)
        ]
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Arc Kit · 彩色菜单栏标志").font(.system(size: 19, weight: .semibold))
            HStack(spacing: 12) {
                ForEach(samples.indices, id: \.self) { index in
                    let sample = samples[index]
                    VStack(spacing: 18) {
                        Text(sample.0).font(.system(size: 12, weight: .medium)).foregroundStyle(sample.2.opacity(0.75))
                        Image(nsImage: MenuBarIconArtwork.detailPreview).frame(width: 114, height: 54)
                        Image(nsImage: MenuBarIconArtwork.combined).frame(width: 58, height: 28)
                    }.frame(width: 156, height: 156)
                        .background(sample.1, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.padding(24).frame(width: 708, height: 240).background(Color.white)
        try await writeSettingsImage(view, size: CGSize(width: 708, height: 240), scheme: .light, to: url)
    }

    private static func writeIconAnimationPreview(to directory: URL) throws {
        let url = directory.appendingPathComponent("menu-bar-animation-preview.gif")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
            MenuBarIconArtwork.animationFrameCount + 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let keyframes = directory.appendingPathComponent("animation-frames")
        try FileManager.default.createDirectory(at: keyframes, withIntermediateDirectories: false)
        for index in 0...MenuBarIconArtwork.animationFrameCount {
            let isRest = index == MenuBarIconArtwork.animationFrameCount
            let bitmap = try iconAnimationPreviewFrame(isRest ? nil : index)
            guard let image = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
            let delay = isRest ? MenuBarIconArtwork.animationRestInterval : MenuBarIconArtwork.animationFrameInterval
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            if [0, 8, 19, 30, 39].contains(index) {
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: keyframes.appendingPathComponent("frame-\(index).png"))
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 动图只合成离屏素材，动效帧和时长均来自正式菜单栏实现，不创建系统状态项。
    private static func iconAnimationPreviewFrame(_ index: Int?) throws -> NSBitmapImageRep {
        let size = NSSize(width: 400, height: 180)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 360,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor(srgbRed: 0.31, green: 0.31, blue: 0.21, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.72)]
        ("Arc Kit · 菜单栏流光" as NSString).draw(at: NSPoint(x: 24, y: 142), withAttributes: title)
        ("每轮 2 秒动效 · 6 秒静置" as NSString).draw(at: NSPoint(x: 24, y: 123), withAttributes: label)
        let detail = index.map { MenuBarIconArtwork.animationDetailPreview(frame: $0) } ?? MenuBarIconArtwork.detailPreview
        let actual = index.map { MenuBarIconArtwork.frame($0, collectionVisible: true) } ?? MenuBarIconArtwork.combined
        detail.draw(in: NSRect(x: 40, y: 55, width: 114, height: 54))
        actual.draw(in: NSRect(x: 285, y: 73, width: 38, height: 18))
        ("放大细节" as NSString).draw(at: NSPoint(x: 75, y: 27), withAttributes: label)
        ("菜单栏原尺寸" as NSString).draw(at: NSPoint(x: 271, y: 27), withAttributes: label)
        return bitmap
    }

    private static func writeSettingsImage<Content: View>(_ view: Content, size: CGSize, scheme: ColorScheme, to url: URL) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    private static func export(to directory: URL) -> Int32 {
        do {
            // 探测报告含本机应用清单，要求新目录且只允许当前用户读取，避免覆盖历史证据。
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            let inventory = MenuBarInspector().capture()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(inventory).write(to: directory.appendingPathComponent("inventory.json"), options: .atomic)
            print("MENU_BAR_PROBE inventory=\(directory.appendingPathComponent("inventory.json").path) displays=\(inventory.displays.count) items=\(inventory.items.count) identityCandidates=\(inventory.persistentIdentityCount) issues=\(inventory.issues.count) accessibility=\(inventory.accessibility.rawValue)")
            print("MENU_BAR_PROBE scope=read-only actions=not-run sorting=not-run hiding=not-run systemOverlay=not-run")
            return inventory.accessibility == .granted && inventory.canUseGeometry ? 0 : 3
        } catch {
            print(L10n.string(.MenuBar.probeFailure(error.localizedDescription)))
            return 1
        }
    }
}

@MainActor
private final class WorkflowPreviewDriver: MenuBarPartitionDriving {
    func install(deepSectionEnabled: Bool) {}
    func present(_ state: MenuBarPresentation) async throws { try Task.checkCancellation() }
    func remove() {}
    func refreshLabels() {}
    func revealAll() {}
    func confirmRevealedLayout() async throws {}
    func layoutSnapshot() throws -> MenuBarPartitionSnapshot { throw MenuBarPartitionError.unavailable }
}
@MainActor
private final class WorkflowPreviewHotKeys: MenuBarHotKeyDriving {
    func apply(_ shortcuts: [MenuBarHotKeyAction: HotKeyChord], action: @escaping (MenuBarHotKeyAction) -> Void) -> [MenuBarHotKeyAction: Int32] { [:] }
    func stop() {}
}
@MainActor
private final class WorkflowPreviewPanel: MenuBarShelfPresenting {
    var onDismiss: (() -> Void)?
    var isVisible = false
    func show() throws -> UInt32 { isVisible = true; return 900 }
    func close() { isVisible = false }
}
#endif
