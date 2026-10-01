import ArcKitPlatform
import AppKit
import Foundation

/// 统一判断 Finder 菜单中的目标 App 是否真实可用，避免显示点击后必然失败的幽灵入口。
public enum FavoriteApplicationAvailabilityResolver {
    public static func isAvailable(
        _ application: FavoriteApplication,
        fileManager: FileManager = .default,
        bundleURLResolver: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    ) -> Bool {
        if let appPath = application.appPath,
           fileManager.fileExists(atPath: appPath) {
            return true
        }
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return bundleURLResolver(bundleIdentifier) != nil
    }
}
