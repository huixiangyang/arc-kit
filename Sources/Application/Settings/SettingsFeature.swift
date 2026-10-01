import ArcKitPlatform

enum SettingsFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .preferences, title: L10n.string(.Common.settings), icon: .settings, commands: { commands + AppearanceFeature.commands })
    }

    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "preferences.application", L10n.string(.App.searchSettingsGeneral), L10n.string(.App.searchGeneralDescription), .settings, L10n.string(.Common.settings),
                ["语言", "language", "English", "简体中文", "通用", "系统设置", "深色", "浅色", "开机启动", "菜单栏", "托盘", "图标", "显示隐藏文件", "截图目录", "系统", "appearance", "dock", "menu bar", "tray", "login", "screenshot", "hidden files"], .preferences(.application), order: 40
            ),
            ArcKitQuickCommand.command(
                "preferences.data", L10n.string(.App.searchSettingsDataManagement), L10n.string(.App.searchDataDescription), .hardDrive, L10n.string(.Common.settings),
                ["存储", "缓存", "清理", "迁移", "备份", "恢复", "导出设置", "导入设置", "重置", "维护", "卸载", "诊断报告", "storage", "backup", "restore", "uninstall"], .preferences(.dataManagement), order: 42
            ),
            ArcKitQuickCommand.command(
                "preferences.about", L10n.string(.App.searchSettingsAboutUpdates), L10n.string(.App.searchVersionPrivacyUpdateChecks), .circleInfo, L10n.string(.Common.settings),
                ["版本", "更新", "隐私", "update", "version"], .preferences(.about), suggested: true, order: 43
            )
        ]
    }
}
