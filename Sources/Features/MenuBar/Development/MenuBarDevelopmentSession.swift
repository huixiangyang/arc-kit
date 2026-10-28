#if DEBUG
import ArcKitPlatform
import ArcKitFinder
import AppKit
import Darwin
import SwiftUI

/// 在 StorageBootstrap 之前分流；不读取生产数据库、不注册 Host。
@MainActor
public enum MenuBarDevelopmentSession {
    public static func handle(arguments: [String]) -> Int32? {
        if arguments.contains("--menu-bar-native-check") || arguments.contains("--menu-bar-width-check") {
            guard arguments.count == 3, ["--menu-bar-native-check", "--menu-bar-width-check"].contains(arguments[1]) else {
                print("Usage: ArcKitApp (--menu-bar-native-check | --menu-bar-width-check) <new-directory>"); return 2
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let check = MenuBarNativeCheck(directory: URL(fileURLWithPath: arguments[2]), measuresWidths: arguments[1] == "--menu-bar-width-check")
            Task { Darwin.exit(await check.run()) }
            application.run()
            return 0
        }
        if let index = arguments.firstIndex(of: "--menu-bar-render") {
            guard index == 1, arguments.count == 3 else { print(L10n.string(.MenuBar.probeUsage)); return 2 }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.finishLaunching()
            let directory = URL(fileURLWithPath: arguments[2])
            Task { Darwin.exit(await exportSettings(to: directory)) }
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
            let service = MenuBarManagementService(isPreview: true)
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    for tab in MenuBarWorkspaceTab.allCases {
                        let view = MenuBarSection(model: model.menuBarEditor, service: service, selectedTab: .constant(tab))
                            .frame(width: 780, height: 820).environment(\.colorScheme, scheme).environment(\.locale, L10n.locale)
                        try await writeSettingsImage(view, size: CGSize(width: 780, height: 820), scheme: scheme,
                            to: directory.appendingPathComponent("settings-\(tab.rawValue)-\(scheme == .light ? "light" : "dark")-\(language.rawValue).png"))
                    }
                }
            }
            let partitionPreview = MenuBarManagementService(isPreview: true, partitionMode: .offscreen)
            L10n.configure(.simplifiedChinese)
            let partitionView = MenuBarSection(model: model.menuBarEditor, service: partitionPreview, selectedTab: .constant(.organize))
                .frame(width: 780, height: 820).environment(\.colorScheme, .light).environment(\.locale, L10n.locale)
            try await writeSettingsImage(partitionView, size: CGSize(width: 780, height: 820), scheme: .light,
                to: directory.appendingPathComponent("settings-organize-offscreen.png"))
            // 实际内容区最小宽度为 480；额外检查中文窄布局，而非只验收宽屏画面。
            L10n.configure(.simplifiedChinese)
            for tab in MenuBarWorkspaceTab.allCases {
                let view = MenuBarSection(model: model.menuBarEditor, service: service, selectedTab: .constant(tab))
                    .frame(width: 480, height: 820).environment(\.colorScheme, .light).environment(\.locale, L10n.locale)
                try await writeSettingsImage(view, size: CGSize(width: 480, height: 820), scheme: .light,
                    to: directory.appendingPathComponent("settings-\(tab.rawValue)-narrow.png"))
            }
            for language in [ArcKitLanguage.simplifiedChinese, .english] {
                L10n.configure(language)
                for scheme in [ColorScheme.light, .dark] {
                    let shelf = MenuBarShelfModel()
                    shelf.supportsCollectedScope = MenuBarPartitionMode.current.supportsSections
                    let inventory = shelfPreviewInventory()
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
                    shelf.load(shelfPreviewInventory())
                    shelf.feedback = MenuBarItemAccessError.requestUnconfirmed(-25204).localizedDescription
                }
                else if state == "collection-unavailable" {
                    shelf.scope = .collected; shelf.load(shelfPreviewInventory())
                } else if state == "collection-ambiguous" {
                    shelf.scope = .collected
                    let inventory = shelfPreviewInventory(includingUnknown: true)
                    shelf.load(inventory, partition: try shelfPreviewPartition(inventory), targetDisplayID: 900)
                }
                let size = CGSize(width: 540, height: shelf.preferredHeight)
                let view = MenuBarShelfView(model: shelf, refresh: {}, close: {}, openPermission: {}, showAll: {}, isPreview: true)
                    .frame(width: size.width, height: size.height).environment(\.colorScheme, .light).environment(\.locale, L10n.locale)
                try await writeSettingsImage(view, size: size, scheme: .light,
                    to: directory.appendingPathComponent("shelf-\(state).png"))
            }
            print("MENU_BAR_SETTINGS_RENDER path=\(directory.path) images=30 runtime=preview")
            return 0
        } catch {
            print(L10n.string(.MenuBar.probeFailure(error.localizedDescription)))
            return 1
        }
    }

    private static func shelfPreviewInventory(includingUnknown: Bool = false) -> MenuBarInventory {
        let display = MenuBarDisplay(id: 900, name: "Preview", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: nil, scale: 2)
        let names = ["Build Monitor", "Clipboard", "Cloud Sync", "Focus Timer", "Network", "Notes"] + (includingUnknown ? ["Unclassified"] : [])
        let positions: [CGFloat] = [1000, 1040, 800, 840, 1200, 1240, 1090]
        let items = names.enumerated().map { index, name in
            MenuBarObservedItem(id: UUID(), processID: 900001, processLaunchDate: Date(timeIntervalSince1970: 100),
                bundleIdentifier: "preview." + name.lowercased().replacingOccurrences(of: " ", with: "-"),
                applicationName: name, accessibilityIdentifier: nil,
                frame: CGRect(x: positions[index], y: 4, width: 22, height: 22), displayID: display.id,
                declaresPress: true, declaresShowMenu: false, positionSettable: false)
        }
        return .init(id: UUID(), capturedAt: Date(), systemVersion: "Preview", accessibility: .granted, displays: [display], items: items, issues: [])
    }

    private static func shelfPreviewPartition(_ inventory: MenuBarInventory) throws -> MenuBarPartitionSnapshot {
        try .init(generation: 1, displays: inventory.displays, control: CGRect(x: 1300, y: 4, width: 18, height: 22),
            hidden: CGRect(x: 1100, y: 4, width: 18, height: 22), deep: CGRect(x: 900, y: 4, width: 18, height: 22))
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

#endif
