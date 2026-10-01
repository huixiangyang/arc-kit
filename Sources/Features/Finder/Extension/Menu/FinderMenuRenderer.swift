import ArcKitFinder
import ArcKitPlatform
import AppKit
import Foundation

/// Finder 菜单热路径只消费菜单树和已绘制图标，不查询应用或携带 IconServices 惰性图片。
enum FinderMenuRenderer {
    static func buildMenu(
        state: FinderMenuRuntimeState,
        icons: FinderMenuIcons,
        context: FinderMenuBuildContext,
        actionTarget: FinderContextCollector.ActionTargetSnapshot
    ) -> NSMenu? {
        guard state.isEnabled else { return nil }

        let menu = NSMenu(title: "Arc Kit")
        render(entries: buildEntries(state: state, context: context), into: menu, icons: icons, actionTarget: actionTarget)
        // 用户关闭所有模块或当前目标不适用时，空菜单不是扩展故障。
        return menu.items.isEmpty ? nil : menu
    }

    static func buildEntries(state: FinderMenuRuntimeState, context: FinderMenuBuildContext) -> [FinderMenuEntry] {
        FinderMenuTreeBuilder.buildEntries(state: state.treeState, context: context.targetContext)
    }

    private static func render(
        entries: [FinderMenuEntry],
        into menu: NSMenu,
        icons: FinderMenuIcons,
        actionTarget: FinderContextCollector.ActionTargetSnapshot
    ) {
        for entry in entries {
            switch entry {
            case let .action(descriptor):
                if let item = makeActionItem(descriptor, actionTarget: actionTarget) {
                    item.image = icons.image(for: descriptor)
                    menu.addItem(item)
                }
            case let .submenu(_, title, _, _, children):
                let submenu = NSMenu(title: title)
                render(entries: children, into: submenu, icons: icons, actionTarget: actionTarget)
                guard !submenu.items.isEmpty else { continue }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                item.image = icons.image(for: entry)
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    private static func makeActionItem(
        _ descriptor: FinderActionDescriptor,
        actionTarget: FinderContextCollector.ActionTargetSnapshot
    ) -> NSMenuItem? {
        guard FinderMenuActionPolicy.allows(descriptor) else {
            ArcKitLog.append(
                "finder menu action hidden unregistered id=\(descriptor.actionID) " +
                "kind=\(descriptor.actionKind.rawValue) command=\(descriptor.commandKind.rawValue)"
            )
            return nil
        }
        let item = NSMenuItem(
            title: descriptor.title,
            action: NSSelectorFromString("performMenuAction:"),
            keyEquivalent: ""
        )
        // Finder Sync 在真实 Finder 中把 action 派发给扩展主对象，不能绑定自定义 target。
        item.target = nil
        item.tag = FinderMenuActionRegistry.register(descriptor, target: actionTarget)
        guard item.tag > 0 else { return nil }
        item.isEnabled = descriptor.isEnabled
        return item
    }
}

/// 与预览共用快照到菜单树的转换。没有默认菜单或第二条文件缓存刷新路径。
struct FinderMenuRuntimeState {
    let snapshotVersion: Int
    let isEnabled: Bool
    let treeState: FinderMenuTreeState

    init(snapshot: FinderExtensionSnapshot) {
        snapshotVersion = snapshot.schemaVersion
        isEnabled = snapshot.menuProfile.isEnabled
        treeState = FinderMenuTreeState(snapshot: snapshot)
    }
}
