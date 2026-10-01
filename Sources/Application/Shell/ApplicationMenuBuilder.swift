import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit

/// 构建完整的 macOS 主菜单，让任务导航、窗口控制和设置历史具备系统级键盘语义。
@MainActor
enum ApplicationMenuBuilder {
    static func install(target: AppController) {
        let mainMenu = NSMenu(title: "Arc Kit")
        mainMenu.addItem(rootItem(title: "Arc Kit", submenu: applicationMenu(target: target)))
        mainMenu.addItem(rootItem(title: L10n.string(.App.menuNavigate), submenu: navigationMenu(target: target)))
        mainMenu.addItem(rootItem(title: L10n.string(.App.menuEdit), submenu: editMenu(target: target)))
        mainMenu.addItem(rootItem(title: L10n.string(.Common.windows), submenu: windowMenu()))
        let help = helpMenu(target: target)
        mainMenu.addItem(rootItem(title: L10n.string(.App.menuHelp), submenu: help))
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu
    }

    private static func applicationMenu(target: AppController) -> NSMenu {
        let menu = NSMenu(title: "Arc Kit")
        menu.addItem(item(title: L10n.string(.App.menuAboutArcKit), action: #selector(AppController.showAbout), target: target))
        menu.addItem(item(title: L10n.string(.App.menuCheckUpdates), action: #selector(AppController.checkForUpdates), target: target))
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuShowMainWindow), action: #selector(AppController.showMainWindow), target: target))
        menu.addItem(item(title: L10n.string(.App.menuSettings), action: #selector(AppController.showPreferences), key: ",", target: target))
        menu.addItem(item(title: L10n.string(.Common.reload), action: #selector(AppController.reloadSettings), key: "r", target: target))
        menu.addItem(.separator())

        let services = NSMenu(title: L10n.string(.App.menuServices))
        let servicesItem = NSMenuItem(title: L10n.string(.App.menuServices), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuHideArcKit), action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        let hideOthers = item(
            title: L10n.string(.App.menuHideOthers),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            target: NSApp
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item(title: L10n.string(.App.menuShowAll), action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuQuitArcKit), action: #selector(AppController.quit), key: "q", target: target))
        return menu
    }

    /// 一级任务使用连续快捷键；菜单名称与侧栏保持一致。
    private static func navigationMenu(target: AppController) -> NSMenu {
        let menu = NSMenu(title: L10n.string(.App.menuNavigate))
        menu.addItem(item(title: L10n.string(.App.menuQuickFind), action: #selector(AppController.showQuickFind), key: "k", target: target))
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.Common.home), action: #selector(AppController.showOverview), key: "1", target: target))
        menu.addItem(item(title: "Finder", action: #selector(AppController.showFinderSection), key: "2", target: target))
        menu.addItem(item(title: L10n.string(.Common.windows), action: #selector(AppController.showWindowSection), key: "3", target: target))
        menu.addItem(item(title: L10n.string(.Common.mouse), action: #selector(AppController.showMouseSection), key: "4", target: target))
        menu.addItem(item(title: L10n.string(.Common.wallpaper), action: #selector(AppController.showWallpaperSection), key: "5", target: target))
        menu.addItem(item(title: L10n.string(.Common.settings), action: #selector(AppController.showPreferences), key: "6", target: target))
        return menu
    }

    private static func editMenu(target: AppController) -> NSMenu {
        let menu = NSMenu(title: L10n.string(.App.menuEdit))
        menu.addItem(item(title: L10n.string(.Common.undo), action: #selector(AppController.undoSettings), key: "z", target: target))
        let redo = item(title: L10n.string(.Common.redo), action: #selector(AppController.redoSettings), key: "z", target: target)
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuCut), action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item(title: L10n.string(.App.menuCopy), action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item(title: L10n.string(.App.menuPaste), action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item(title: L10n.string(.App.menuSelectAll), action: #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string(.Common.windows))
        menu.addItem(item(title: L10n.string(.App.menuCloseWindow), action: #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(item(title: L10n.string(.App.menuMinimize), action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item(title: L10n.string(.App.menuZoom), action: #selector(NSWindow.performZoom(_:))))
        let fullScreen = item(title: L10n.string(.App.menuEnterFullScreen), action: #selector(NSWindow.toggleFullScreen(_:)), key: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuBringAllFront), action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu(target: AppController) -> NSMenu {
        let menu = NSMenu(title: L10n.string(.App.menuHelp))
        let guide = item(title: L10n.string(.App.menuArcKitUserGuide), action: #selector(AppController.showOverview), key: "?", target: target)
        menu.addItem(guide)
        menu.addItem(.separator())
        menu.addItem(item(title: L10n.string(.App.menuUsingFinderContextMenus), action: #selector(AppController.showFinderSection), target: target))
        menu.addItem(item(title: L10n.string(.App.menuUsingWindowManagement), action: #selector(AppController.showWindowSection), target: target))
        menu.addItem(item(title: L10n.string(.App.menuUsingMouseEnhancement), action: #selector(AppController.showMouseSection), target: target))
        return menu
    }

    private static func rootItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(
        title: String,
        action: Selector,
        key: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
