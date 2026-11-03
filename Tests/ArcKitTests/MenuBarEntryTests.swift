import AppKit
import Testing
@testable import ArcKitApplication

@Suite("单状态项组合入口")
struct MenuBarEntryTests {
    @Test("左侧切换、右侧菜单互不串用，繁忙时仍可打开菜单，停用后只保留品牌")
    @MainActor func combinedActions() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 54, height: 22))
        var collapsed = 0, revealed = 0, menus = 0
        let entry = MenuBarCombinedEntry(button: button, collapse: { collapsed += 1 }, reveal: { revealed += 1 }, openMenu: { menus += 1 })
        entry.update(collectionVisible: true, presentation: .all, ready: true, busy: false, menuStatus: "Menu")
        let image = button.image
        #expect(image?.isValid == true && image?.isTemplate == true)
        #expect(entry.perform(.collection) && collapsed == 1 && menus == 0)
        #expect(!entry.perform(.collection))
        entry.update(collectionVisible: true, presentation: .all, ready: true, busy: true, menuStatus: "Menu")
        #expect(!entry.perform(.collection) && entry.perform(.menu) && menus == 1)
        entry.update(collectionVisible: true, presentation: .collapsed, ready: true, busy: false, menuStatus: "Menu")
        #expect(button.image === image)
        #expect(entry.perform(.collection) && revealed == 1)
        entry.update(collectionVisible: true, presentation: .all, ready: false, busy: false, menuStatus: "Menu", collectionMessage: "恢复失败")
        #expect(entry.perform(.collection) && revealed == 2)
        #expect(button.toolTip?.contains("恢复失败") == true)
        entry.update(collectionVisible: false, presentation: .all, ready: true, busy: false, menuStatus: "Menu")
        #expect(button.image?.size.width == 18 && !entry.perform(.collection))
        button.performClick(nil)
        #expect(menus == 2)
    }

    @Test("图像边界决定左右命中；右键和键盘打开菜单，Command拖动不执行动作")
    @MainActor func hitRegions() {
        let rect = CGRect(x: 8, y: 2, width: 38, height: 18)
        func hit(_ x: CGFloat?, secondary: Bool = false, drag: Bool = false, visible: Bool = true) -> MenuBarCombinedEntry.Region? {
            MenuBarCombinedEntry.region(at: x.map { CGPoint(x: $0, y: 11) }, imageRect: rect,
                collectionVisible: visible, secondary: secondary, commandDrag: drag)
        }
        #expect(hit(8) == .collection && hit(25.9) == .collection)
        #expect(hit(26) == .menu && hit(53) == .menu)
        #expect(hit(nil) == .menu && hit(8, secondary: true) == .menu)
        #expect(hit(8, drag: true) == nil && hit(8, visible: false) == .menu)
        // 原生代理合成的事件中心为(27,11)，真实指针仍应命中左侧；移位或键盘触发不猜位置。
        let frame = CGRect(x: 895, y: 954.5, width: 54, height: 22)
        let local = MenuBarCombinedEntry.localPoint(pointer: CGPoint(x: 905, y: 966), screenFrame: frame, bounds: CGRect(x: 0, y: 0, width: 54, height: 22))
        #expect(local?.x == 10 && hit(local?.x) == .collection)
        let padded = MenuBarCombinedEntry.localPoint(pointer: CGPoint(x: 905, y: 951), screenFrame: frame,
            bounds: CGRect(x: 0, y: 0, width: 54, height: 22), hitFrame: CGRect(x: 894, y: 948, width: 56, height: 34))
        #expect(padded?.x == 10 && hit(padded?.x) == .collection)
        #expect(MenuBarCombinedEntry.localPoint(pointer: .zero, screenFrame: frame, bounds: CGRect(x: 0, y: 0, width: 54, height: 22)) == nil)
    }
}
