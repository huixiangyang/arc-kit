import ArcKitPlatform

struct ApplicationFeatureEntry {
    let section: MainWindowSection
    let title: String
    let icon: ArcIconName
    let commands: () -> [ArcKitQuickCommand]
}

/// 只有这里决定侧栏功能的顺序；标题、图标与搜索项由各功能声明。
enum ApplicationFeatureCatalog {
    static var primary: [ApplicationFeatureEntry] {
        [OverviewFeature.entry, FinderFeature.entry, WindowFeature.entry, MouseFeature.entry, WallpaperFeature.entry]
    }
    static var secondary: [ApplicationFeatureEntry] { [SettingsFeature.entry] }
    static var all: [ApplicationFeatureEntry] { primary + secondary }

    static func entry(for section: MainWindowSection) -> ApplicationFeatureEntry {
        guard let entry = all.first(where: { $0.section == section }) else {
            preconditionFailure("Missing application feature: \(section)")
        }
        return entry
    }
}
