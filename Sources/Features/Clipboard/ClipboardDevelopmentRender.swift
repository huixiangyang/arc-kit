#if DEBUG
import ArcKitPlatform
import ArcKitFinder
import AppKit
import Darwin
import SwiftUI

/// 只使用临时数据和不可见窗口，不读取系统剪贴板、联网、注册快捷键或启动 Host。
@MainActor
public enum ClipboardDevelopmentRender {
    public static func handle(arguments: [String]) -> Int32? {
        guard arguments.contains(where: { $0.hasPrefix("--clipboard-") }) else { return nil }
        guard arguments.count == 3, arguments[1] == "--clipboard-render" else { return 2 }
        let directory = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: directory.path) else { return 2 }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited); application.finishLaunching()
        Task {
            do { try await render(to: directory); print("CLIPBOARD_RENDER \(directory.path)"); Darwin.exit(0) }
            catch { print(error.localizedDescription); Darwin.exit(1) }
        }
        application.run(); return 0
    }

    private static func render(to directory: URL) async throws {
        try ArcKitStoragePaths.secureDirectory(directory)
        let dataRoot = directory.appendingPathComponent("fixture")
        let repository = SettingsRepository(directoryURL: dataRoot)
        defer { try? repository.database.close() }
        var settings = try repository.load(); settings.clipboard.isEnabled = true
        try repository.save(settings)
        let settingsModel = SettingsModel(store: repository,
            templateLibrary: NewFileTemplateLibrary(baseDirectory: repository.database.paths.templates))
        let store = ClipboardStore(database: repository.database)
        let samples = [
            ("发布检查清单\n\n- 核对版本号与构建号\n- 导出设置备份\n- 检查更新说明\n- 验证正常退出与重启", "Notes", "com.apple.Notes"),
            ("https://github.com/huixiangyang/arc-kit", "Safari", "com.apple.Safari"),
            ("git status --short --branch\nswift build", "Terminal", "com.apple.Terminal"),
            ("{\n  \"format\": \"png\",\n  \"overwrite\": false\n}", "TextEdit", "com.apple.TextEdit"),
        ]
        for (index, sample) in samples.enumerated() {
            var item = ClipboardItem(content: .init(kind: index == 1 ? .link : .text, text: sample.0),
                sourceBundleID: sample.2, sourceName: sample.1, deviceName: "Studio Mac")
            item.favorite = index == 0
            item.createdAt = Date().addingTimeInterval(-Double(index * 200))
            try store.insert(item, account: nil)
        }
        let model = ClipboardModel(store: store, settingsModel: settingsModel, isPreview: true)
        model.reload()
        for _ in 0..<50 {
            if !settingsModel.isLoading, !model.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for language in [ArcKitLanguage.simplifiedChinese, .english] {
            L10n.configure(language)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(language.rawValue)-\(scheme == .light ? "light" : "dark")"
                try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
                    size: CGSize(width: 760, height: 540), scheme: scheme, to: directory.appendingPathComponent("history-\(suffix).png"))
                try await image(ClipboardPreferencesView(editor: settingsModel.clipboardEditor, model: model),
                    size: CGSize(width: 558, height: 690), scheme: scheme, to: directory.appendingPathComponent("settings-\(suffix).png"))
            }
        }
        L10n.configure(.simplifiedChinese)
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
            size: CGSize(width: 600, height: 460), scheme: .light, to: directory.appendingPathComponent("history-compact.png"))
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor),
            size: CGSize(width: 500, height: 560), scheme: .light, to: directory.appendingPathComponent("history-narrow-page.png"))
        guard let tiff = ArcBrandImage.logo(for: .light).tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw ClipboardError.invalidContent }
        let picture = ClipboardItem(content: .init(kind: .image, png: png), sourceBundleID: "test.preview", sourceName: "Preview", deviceName: "Studio Mac")
        try store.insert(picture, account: nil)
        model.select(picture.id)
        for _ in 0..<50 {
            if model.selectedItem?.id == picture.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
            size: CGSize(width: 760, height: 540), scheme: .light, to: directory.appendingPathComponent("history-image.png"))
        let cloudPreview = ClipboardModel(store: store, settingsModel: settingsModel, isPreview: true, cloud: ClipboardRenderCloud())
        L10n.configure(.english)
        try await image(ClipboardPreferencesView(editor: settingsModel.clipboardEditor, model: cloudPreview),
            size: CGSize(width: 558, height: 690), scheme: .dark, to: directory.appendingPathComponent("settings-cloud.png"))
        L10n.configure(.simplifiedChinese)
        model.search = "no-matching-fixture"; model.reload()
        for _ in 0..<50 {
            if model.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
            size: CGSize(width: 600, height: 460), scheme: .light, to: directory.appendingPathComponent("history-no-matches.png"))
        try store.clearLocal(account: nil)
        model.search = ""; model.reload()
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
            size: CGSize(width: 600, height: 460), scheme: .light, to: directory.appendingPathComponent("history-empty.png"))
        settingsModel.clipboardEditor.update { $0.isEnabled = false }
        guard await settingsModel.clipboardEditor.commitPendingChanges() else { throw ClipboardError.invalidSettings }
        for _ in 0..<50 {
            if !model.settings.isEnabled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await image(ClipboardView(model: model, editor: settingsModel.clipboardEditor, compact: true),
            size: CGSize(width: 600, height: 460), scheme: .dark, to: directory.appendingPathComponent("history-paused.png"))
    }

    private static func image<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, to url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).background(ArcPalette.background))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host; host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}

private actor ClipboardRenderCloud: ClipboardCloudTransport {
    func account() async throws -> String { throw ClipboardError.unavailable }
    func prepare() async throws { throw ClipboardError.unavailable }
    func fetch(token: Data?) async throws -> ClipboardCloudPage { throw ClipboardError.unavailable }
    func save(_ uploads: [ClipboardUpload]) async throws -> ClipboardCloudSaveResult { throw ClipboardError.unavailable }
}
#endif
