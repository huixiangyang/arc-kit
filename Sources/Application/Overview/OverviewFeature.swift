import ArcKitPlatform

enum OverviewFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .overview, title: L10n.string(.Common.home), icon: .house, commands: { commands })
    }

    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "section.overview", L10n.string(.Common.home), L10n.string(.App.searchPermissionsFeatureStatus), .house, L10n.string(.App.searchPages),
                ["运行状态", "总览", "指南", "home", "overview"], .section(.overview), suggested: false, order: 0
            ),
            ArcKitQuickCommand.command(
                "home.permissions", L10n.string(.App.searchPermissionCheck), L10n.string(.App.searchAccessibilityFinderExtensionPermissions), .shieldCheck, L10n.string(.Common.home),
                ["授权", "权限", "permission", "accessibility"], .overview(.permissions), order: 1
            ),
            ArcKitQuickCommand.command(
                "home.diagnostics", L10n.string(.App.searchFeatureDiagnostics), L10n.string(.App.searchFinderConnectionScrollInputSamples), .activity, L10n.string(.Common.home),
                ["检测", "运行状态", "后台", "滚轮", "diagnostics"], .overview(.diagnostics), order: 2
            )
        ]
    }
}
