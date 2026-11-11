import ArcKitPlatform
import Carbon.HIToolbox
import Foundation

@MainActor
protocol InputSourceAccess: AnyObject {
    func read() throws -> InputSourceConfiguration
    func write(_ configuration: InputSourceConfiguration) throws
    func inventory() -> [InputSourceDescriptor]
    func loadRecovery() throws -> InputSourceRecovery?
    func saveRecovery(_ recovery: InputSourceRecovery) throws
    func clearRecovery() throws
}

/// 所有 TIS 调用留在主线程；不执行 shell，不重启 cfprefsd、输入法或登录会话。
@MainActor
final class NativeInputSourceAccess: InputSourceAccess {
    private let domain: CFString
    private let recoveryURL: URL
    init(recoveryURL: URL, preferenceDomain: String = "com.apple.HIToolbox") {
        self.recoveryURL = recoveryURL
        domain = preferenceDomain as CFString
    }

    func read() throws -> InputSourceConfiguration {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw InputSourceToolError.invalidConfiguration }
        var values: [String: Any] = [:]
        for key in InputSourceConfiguration.keys {
            // 仅当前用户、任意主机域；存在同名 ByHost 覆盖时拒绝写入不明确的目标。
            guard CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) == nil else {
                throw InputSourceToolError.invalidConfiguration
            }
            values[key] = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return try InputSourceConfiguration(propertyList: values)
    }

    func write(_ configuration: InputSourceConfiguration) throws {
        for key in InputSourceConfiguration.keys {
            let value = configuration.propertyList[key]
            CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { throw InputSourceToolError.writeFailed }
    }

    func inventory() -> [InputSourceDescriptor] {
        let filter = [kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        func property(_ source: TISInputSource, _ key: CFString) -> Any? {
            guard let value = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        }
        let enabledParents = Set(list.compactMap { source -> String? in
            guard property(source, kTISPropertyInputSourceType) as? String == kTISTypeKeyboardInputMethodModeEnabled as String,
                  property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true else { return nil }
            return property(source, kTISPropertyBundleID) as? String
        })
        return list.compactMap { source in
            guard let id = property(source, kTISPropertyInputSourceID) as? String,
                  let name = property(source, kTISPropertyLocalizedName) as? String else { return nil }
            let bundleID = property(source, kTISPropertyBundleID) as? String ?? ""
            var layoutNames: Set<String> = []
            if property(source, kTISPropertyInputSourceType) as? String == kTISTypeKeyboardLayout as String {
                // 偏好保存原始布局名，TIS 返回本地化名称；用所属 bundle 的名称表对应，不猜 ID。
                layoutNames.insert(name)
                for (key, value) in Bundle(identifier: bundleID)?.localizedInfoDictionary ?? [:] where value as? String == name {
                    layoutNames.insert(key)
                }
            }
            return InputSourceDescriptor(id: id, bundleID: bundleID,
                modeID: property(source, kTISPropertyInputModeID) as? String, name: name,
                enabled: property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true,
                selectable: property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool == true, layoutNames: layoutNames)
                .requiringEnabledParent(in: enabledParents)
        }
    }

    func loadRecovery() throws -> InputSourceRecovery? {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return nil }
        try ArcKitStoragePaths.validateFile(recoveryURL)
        let value = try PropertyListDecoder().decode(InputSourceRecovery.self, from: Data(contentsOf: recoveryURL))
        _ = try value.configuration(before: true); _ = try value.configuration(before: false)
        return value
    }
    func saveRecovery(_ recovery: InputSourceRecovery) throws {
        try ArcKitStoragePaths.secureDirectory(recoveryURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: recoveryURL.path) { try ArcKitStoragePaths.validateFile(recoveryURL) }
        try PropertyListEncoder().encode(recovery).write(to: recoveryURL, options: .atomic)
        try ArcKitStoragePaths.secureFile(recoveryURL)
        // 恢复点先持久化，再允许改系统配置；记录不进入可跨机器导入的设置备份。
        let file = try FileHandle(forWritingTo: recoveryURL)
        defer { try? file.close() }
        try file.synchronize()
        try ArcKitStoragePaths.synchronizeDirectory(recoveryURL.deletingLastPathComponent())
    }
    func clearRecovery() throws {
        try ArcKitStoragePaths.validateFile(recoveryURL)
        try FileManager.default.removeItem(at: recoveryURL)
    }
}
