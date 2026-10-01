import ArcKitPlatform

enum FinderFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .finder, title: "Finder", icon: .folder, commands: { commands })
    }

    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "finder.menu", L10n.string(.App.searchFinderMenuItems), L10n.string(.App.searchCreateOpenTerminalCopy), .menu, "Finder",
                ["右键", "排序", "重命名", "压缩", "哈希", "图片", "隐藏", "脚本", "context menu"], .finder(.menu), suggested: true, order: 10
            ),
            ArcKitQuickCommand.command(
                "finder.templates", L10n.string(.App.searchFinderNewFile), L10n.string(.App.searchManageContextMenuFileTemplates), .filePlus, "Finder",
                ["模板", "文本", "文档", "template", "new file"], .finder(.templates), order: 11
            ),
            ArcKitQuickCommand.command(
                "finder.directories", L10n.string(.App.searchFinderFavoriteFolders), L10n.string(.App.searchManageNavigationCopyMoveDestinations), .folderPlus, "Finder",
                ["文件夹", "路径", "工作目录", "收藏", "directory", "favorite"], .finder(.directories), order: 12
            ),
            ArcKitQuickCommand.command(
                "finder.applications", L10n.string(.App.searchFinderFavoriteApps), L10n.string(.App.searchManageContextMenuOpenApps), .appWindow, "Finder",
                ["应用", "编辑器", "终端", "打开方式", "application", "editor"], .finder(.applications), order: 13
            ),
            ArcKitQuickCommand.command(
                "finder.settings", L10n.string(.App.searchFinderScope), L10n.string(.App.searchManageFoldersWhereContextMenusAppear), .activity, "Finder",
                ["外置卷", "目录", "范围", "directory"], .finder(.settings), suggested: true, order: 14
            )
        ]
    }
}
