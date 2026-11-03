import ArcKitPlatform

enum MenuBarFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .menuBar, title: L10n.string(.MenuBar.pageTitle), icon: .panelTop, commands: { [
            .command("section.menu-bar", L10n.string(.MenuBar.pageTitle), L10n.string(.MenuBar.pageDescription),
                .panelTop, L10n.string(.App.searchPages), ["菜单栏", "收纳", "整理图标", "menu bar", "status"],
                .section(.menuBar), order: 45),
            .command("menu-bar.show-all", L10n.string(.MenuBar.actionShowAll), L10n.string(.MenuBar.actionShowAllDetail),
                .eye, L10n.string(.MenuBar.pageTitle), ["显示全部", "恢复图标", "show all", "reveal"],
                .menuBarShowAll, order: 46),
            .command("menu-bar.toggle", L10n.string(.MenuBar.hotKeyToggle), L10n.string(.MenuBar.actionToggleDetail),
                .panelTop, L10n.string(.MenuBar.pageTitle), ["收起", "展开", "toggle", "collapse"], .menuBarToggle, order: 47),
            .command("menu-bar.shelf", L10n.string(.MenuBar.shelfOpen), L10n.string(.MenuBar.shelfDescription),
                .search, L10n.string(.MenuBar.pageTitle), ["收纳栏", "搜索图标", "shelf", "menu bar search"], .menuBarShelf, order: 48)
        ] + (MenuBarPartitionMode.current.supportsSections ? [
            .command("menu-bar.collection", L10n.string(.MenuBar.scopeOpenCollected), L10n.string(.MenuBar.scopeCollectedDetail),
                .archive, L10n.string(.MenuBar.pageTitle), ["普通收纳", "收纳区", "collected", "collection"], .menuBarCollection, order: 49)
        ] : []) })
    }
}
