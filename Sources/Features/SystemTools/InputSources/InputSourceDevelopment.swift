#if DEBUG
import ArcKitPlatform
import AppKit
import Darwin
import SwiftUI

/// 调试窗口和离屏预览只使用内存替身，绝不读取或写入本机输入源。
@MainActor
class InputSourcePreviewAccess: InputSourceAccess {
    static let sogou = InputSourceRecord(raw: ["InputSourceKind": "Input Mode", "Bundle ID": "com.sogou.inputmethod.sogou", "Input Mode": "com.sogou.inputmethod.pinyin"])
    static let abc = InputSourceRecord(raw: ["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 252, "KeyboardLayout Name": "ABC"])
    static let pinyin = InputSourceRecord(raw: ["InputSourceKind": "Input Mode", "Bundle ID": "com.apple.inputmethod.SCIM", "Input Mode": "com.apple.inputmethod.SCIM.ITABC"])
    static let character = InputSourceRecord(raw: ["InputSourceKind": "Non Keyboard Input Method", "Bundle ID": "com.apple.CharacterPaletteIM"])
    static let initial = try! InputSourceConfiguration(propertyList: [
        InputSourceConfiguration.enabledKey: [character.raw, abc.raw, sogou.raw, pinyin.raw],
        InputSourceConfiguration.selectedKey: [sogou.raw], InputSourceConfiguration.historyKey: [abc.raw, sogou.raw]])
    var configuration = initial
    var recovery: InputSourceRecovery?
    var available = [
        InputSourceDescriptor(id: "com.sogou.inputmethod.sogou.pinyin", bundleID: "com.sogou.inputmethod.sogou", modeID: "com.sogou.inputmethod.pinyin", name: "搜狗拼音", enabled: true, selectable: true),
        InputSourceDescriptor(id: "com.apple.keylayout.ABC", bundleID: "", modeID: nil, name: "ABC", enabled: true, selectable: true, layoutNames: ["ABC"]),
        InputSourceDescriptor(id: "com.apple.inputmethod.SCIM.ITABC", bundleID: "com.apple.inputmethod.SCIM", modeID: "com.apple.inputmethod.SCIM.ITABC", name: "拼音", enabled: true, selectable: true)]
    func read() throws -> InputSourceConfiguration { configuration }
    func write(_ configuration: InputSourceConfiguration) throws { self.configuration = configuration }
    func inventory() -> [InputSourceDescriptor] { available }
    func loadRecovery() throws -> InputSourceRecovery? { recovery }
    func saveRecovery(_ recovery: InputSourceRecovery) throws { self.recovery = recovery }
    func clearRecovery() throws { recovery = nil }
}

@MainActor
public enum InputSourceDevelopment {
    public static func handle(arguments: [String]) -> Int32? {
        guard arguments.contains(where: { $0.hasPrefix("--input-source-") }) else { return nil }
        if arguments.contains("--input-source-inspect") {
            guard arguments.count == 2 else { return 2 }
            let access = NativeInputSourceAccess(recoveryURL: ArcKitStoragePaths.current.runtime.appendingPathComponent("input-source-recovery.plist"))
            do {
                let configuration = try access.read(), sources = InputSourceDescriptor.uniqueRecords(access.inventory())
                let names = configuration.keyboards.compactMap { record in
                    let source = record.resolvedDescriptor(in: sources)
                    return source?.enabled == true ? source?.name : nil
                }
                let result: [String: Any] = ["configuredKeyboards": configuration.keyboards.count,
                    "activeKeyboards": sources.filter { $0.enabled && $0.selectable }.count,
                    "availableTargets": names, "mode": "read-only"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); return 0
            } catch { print(error.localizedDescription); return 1 }
        }
        guard arguments.count == 3, arguments[1] == "--input-source-render" else { return 2 }
        let directory = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: directory.path) else { return 2 }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited); application.finishLaunching()
        Task {
            do { try await render(to: directory); print("INPUT_SOURCE_RENDER path=\(directory.path) runtime=preview"); Darwin.exit(0) }
            catch { print(error.localizedDescription); Darwin.exit(1) }
        }
        application.run(); return 0
    }

    private static func render(to directory: URL) async throws {
        try ArcKitStoragePaths.secureDirectory(directory)
        let access = InputSourcePreviewAccess(), model = InputSourceToolModel(access: access)
        model.refresh()
        for language in [ArcKitLanguage.simplifiedChinese, .english] {
            L10n.configure(language)
            for scheme in [ColorScheme.light, .dark] {
                try await image(model, size: CGSize(width: 620, height: 700), scheme: scheme,
                    to: directory.appendingPathComponent("input-sources-\(language.rawValue)-\(scheme == .light ? "light" : "dark").png"))
            }
        }
        L10n.configure(.simplifiedChinese)
        let duplicate = access.available[0]
        access.available += [duplicate, duplicate]; model.refresh()
        for row in model.rows { model.setKept(row.selectionID == InputSourcePreviewAccess.sogou.selectionID, record: row) }
        try await image(model, size: CGSize(width: 620, height: 700), scheme: .light, to: directory.appendingPathComponent("duplicate-registration.png"))
        access.available = InputSourcePreviewAccess().available
        for row in model.rows { model.setKept(true, record: row) }
        model.refresh()
        model.setKept(false, record: InputSourcePreviewAccess.pinyin)
        try await image(model, size: CGSize(width: 620, height: 700), scheme: .light, to: directory.appendingPathComponent("multiple-selected.png"))
        try await image(model, size: CGSize(width: 480, height: 560), scheme: .light, to: directory.appendingPathComponent("narrow.png"))
        model.apply()
        try await image(model, size: CGSize(width: 620, height: 700), scheme: .light, to: directory.appendingPathComponent("pending-login.png"))
        let inactive = access.available[2]
        access.available[2] = InputSourceDescriptor(id: inactive.id, bundleID: inactive.bundleID,
            modeID: inactive.modeID, name: inactive.name, enabled: false, selectable: true)
        model.refresh()
        try await image(model, size: CGSize(width: 620, height: 650), scheme: .dark, to: directory.appendingPathComponent("applied.png"))
        access.configuration = InputSourcePreviewAccess.initial; model.refresh()
        try await image(model, size: CGSize(width: 620, height: 740), scheme: .light, to: directory.appendingPathComponent("changed.png"))
        access.recovery = nil; model.refresh()
        for record in model.rows { model.setKept(false, record: record) }
        try await image(model, size: CGSize(width: 480, height: 650), scheme: .light, to: directory.appendingPathComponent("empty-selection.png"))
        access.available = []; model.refresh()
        try await image(model, size: CGSize(width: 480, height: 650), scheme: .light, to: directory.appendingPathComponent("unavailable.png"))

        // 对照真实问题：配置中有两项，但当前会话只启用搜狗；仍默认全部保留。
        let mismatch = InputSourcePreviewAccess()
        mismatch.configuration = try InputSourceConfiguration(propertyList: [InputSourceConfiguration.enabledKey:
            [InputSourcePreviewAccess.sogou.raw, InputSourcePreviewAccess.pinyin.raw]])
        mismatch.available = [mismatch.available[0], inactive]
        mismatch.available[1] = InputSourceDescriptor(id: inactive.id, bundleID: inactive.bundleID,
            modeID: inactive.modeID, name: inactive.name, enabled: false, selectable: true)
        let mismatchModel = InputSourceToolModel(access: mismatch)
        mismatchModel.refresh()
        for (language, scheme, width) in [(ArcKitLanguage.simplifiedChinese, ColorScheme.light, 620.0), (.english, .dark, 480.0)] {
            L10n.configure(language)
            try await image(mismatchModel, size: CGSize(width: width, height: 650), scheme: scheme,
                to: directory.appendingPathComponent("session-mismatch-\(language.rawValue).png"))
        }
    }

    private static func image(_ model: InputSourceToolModel, size: CGSize, scheme: ColorScheme, to url: URL) async throws {
        let host = NSHostingView(rootView: InputSourceToolView(model: model).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key).background(ArcPalette.background))
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
#endif
