import AppKit
import Testing
@testable import ArcKitApplication

@Suite("单状态项组合入口")
struct MenuBarEntryTests {
    @Test("左侧切换、右侧菜单互不串用，繁忙时仍可打开菜单，停用后只保留品牌")
    @MainActor func combinedActions() {
        // 无桌面 CI 也需要 AppKit 的动作派发入口；不创建窗口或真实状态项。
        _ = NSApplication.shared
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 54, height: 22))
        var collapsed = 0, revealed = 0, menus = 0
        let entry = MenuBarCombinedEntry(button: button, collapse: { collapsed += 1 }, reveal: { revealed += 1 }, openMenu: { menus += 1 })
        entry.update(collectionVisible: true, presentation: .all, ready: true, busy: false, menuStatus: "Menu")
        let image = button.image
        #expect(image?.isValid == true && image?.isTemplate == false)
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
        #expect(button.image?.size.width == 18 && button.image?.isTemplate == false && !entry.perform(.collection))
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

    @Test("流光按缓存帧播放后静置，切换入口不重置帧，暂停拒绝迟到更新")
    @MainActor func animationLifecycle() async throws {
        _ = NSApplication.shared
        let button = NSButton(), clock = MenuBarAnimationClockFixture()
        let entry = MenuBarCombinedEntry(button: button, collapse: {}, reveal: {}, openMenu: {},
            animationSleep: { try await clock.sleep($0) })
        defer { entry.setAnimationEnabled(false); clock.cancel() }
        entry.update(collectionVisible: true, presentation: .all, ready: true, busy: false, menuStatus: "Menu")
        entry.setAnimationEnabled(true)
        for frame in 0..<MenuBarIconArtwork.animationFrameCount {
            try await clock.waitForSleep()
            #expect(clock.duration == .seconds(MenuBarIconArtwork.animationFrameInterval))
            if frame == 10 {
                entry.update(collectionVisible: false, presentation: .all, ready: true, busy: false, menuStatus: "Menu")
            }
            #expect(button.image === MenuBarIconArtwork.frame(frame, collectionVisible: frame < 10))
            #expect(button.image?.size == NSSize(width: frame < 10 ? 38 : 18, height: 18))
            clock.advance()
        }
        try await clock.waitForSleep()
        #expect(clock.duration == .seconds(6) && button.image === MenuBarIconArtwork.brand)
        entry.setAnimationEnabled(false)
        clock.advance()
        await Task.yield()
        #expect(button.image === MenuBarIconArtwork.brand)
        entry.setAnimationEnabled(true)
        try await clock.waitForSleep()
        #expect(button.image === MenuBarIconArtwork.frame(0, collectionVisible: false))
        entry.setAnimationEnabled(false)
        clock.advance()
        await Task.yield()
        #expect(button.image === MenuBarIconArtwork.brand)
    }
}

@MainActor
private final class MenuBarAnimationClockFixture {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var duration: Duration?
    func sleep(_ duration: Duration) async throws {
        self.duration = duration
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForSleep() async throws {
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        try #require(continuation != nil)
    }
    func advance() { let pending = continuation; continuation = nil; pending?.resume() }
    func cancel() { let pending = continuation; continuation = nil; pending?.resume(throwing: CancellationError()) }
}
