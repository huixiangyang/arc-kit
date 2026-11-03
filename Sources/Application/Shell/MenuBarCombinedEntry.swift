import AppKit
import ArcKitPlatform

/// 一个标准状态栏按钮内绘制两个区域；布局和命中边界共用同一尺寸，不能再注册第二个状态项。
@MainActor
final class MenuBarCombinedEntry: NSObject {
    enum Region { case collection, menu }
    static let imageSize = NSSize(width: 38, height: 18)
    static let collectionBoundary: CGFloat = 18
    let button: NSButton
    private let collapse: @MainActor () -> Void
    private let reveal: @MainActor () -> Void
    private let openMenu: @MainActor () -> Void
    private var collectionVisible = false
    private var collectionEnabled = false
    private var shouldCollapse = false

    private static let combinedImage: NSImage = {
        let result = NSImage(size: imageSize)
        let dots = ArcIconImage.image(.ellipsis)
        let brand = ArcBrandImage.menuBar
        // 提前生成两种倍率的模板位图，不把带主执行器隔离的 Swift 绘制闭包交给后台渲染。
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 38 * scale, pixelsHigh: 18 * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = imageSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            dots.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            brand.draw(in: NSRect(x: 20, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(bitmap)
        }
        result.isTemplate = true
        return result
    }()

    init(button: NSButton, collapse: @escaping @MainActor () -> Void, reveal: @escaping @MainActor () -> Void,
         openMenu: @escaping @MainActor () -> Void) {
        self.button = button; self.collapse = collapse; self.reveal = reveal; self.openMenu = openMenu
        super.init()
        button.title = ""; button.imagePosition = .imageOnly
        button.setAccessibilityIdentifier("menu-bar.combined-entry")
        reconnectAction()
    }

    func reconnectAction() {
        button.target = self; button.action = #selector(activate)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    func update(collectionVisible: Bool, presentation: MenuBarPresentation, ready: Bool, busy: Bool, menuStatus: String, collectionMessage: String? = nil) {
        self.collectionVisible = collectionVisible
        shouldCollapse = presentation != .collapsed && ready
        collectionEnabled = !busy
        button.image = collectionVisible ? Self.combinedImage : ArcBrandImage.menuBar
        button.isEnabled = true // 收纳切换期间品牌区域仍可打开功能面板。
        let action = L10n.string(busy ? .MenuBar.entryChanging : (shouldCollapse ? .MenuBar.entryHide : .MenuBar.entryShow))
        button.toolTip = collectionVisible ? L10n.string(.MenuBar.combinedHelp(action, menuStatus)) : "Arc Kit：\(menuStatus)"
        // 面板不再重复展示收纳区，失败反馈保留在实际操作入口的提示中。
        if let collectionMessage, !collectionMessage.isEmpty {
            button.toolTip = (button.toolTip ?? "Arc Kit") + "\n" + collectionMessage
        }
        button.setAccessibilityLabel("Arc Kit")
        button.setAccessibilityHelp(button.toolTip)
        button.setAccessibilityValue(collectionVisible ? L10n.string(busy ? .MenuBar.entryChanging :
            (!ready ? .MenuBar.entryUnavailable : (presentation == .collapsed ? .MenuBar.entryHidden : .MenuBar.entryShown))) : nil)
        button.setAccessibilityCustomActions(collectionVisible ? [
            NSAccessibilityCustomAction(name: action, target: self, selector: #selector(accessibilityToggle))
        ] : [])
    }

    static func region(at point: CGPoint?, imageRect: CGRect, collectionVisible: Bool, secondary: Bool, commandDrag: Bool) -> Region? {
        if commandDrag { return nil }
        // 键盘/辅助功能的默认动作打开面板；只有有效的左侧鼠标命中才触发收纳。
        guard collectionVisible, !secondary, let point, point.x.isFinite, imageRect.width > 0 else { return .menu }
        return point.x < imageRect.minX + collectionBoundary ? .collection : .menu
    }

    @discardableResult
    func perform(_ region: Region) -> Bool {
        switch region {
        case .menu: openMenu(); return true
        case .collection:
            guard collectionVisible, collectionEnabled else { return false }
            collectionEnabled = false
            if shouldCollapse { collapse() } else { reveal() }
            return true
        }
    }

    @objc private func accessibilityToggle() -> Bool { perform(.collection) }

    @objc private func activate() {
        let event = NSApp.currentEvent
        let isMouse = event.map { [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains($0.type) } ?? false
        let screenFrame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
        let point: CGPoint?
        if button is NSStatusBarButton {
            // macOS 27 的代理把事件坐标固定到中心，且可能在释放鼠标后才转发；按真实指针和控件屏幕框命中。
            point = isMouse
                ? Self.localPoint(pointer: NSEvent.mouseLocation, screenFrame: screenFrame, bounds: button.bounds, hitFrame: menuBarHitFrame(screenFrame)) : nil
        } else {
            point = isMouse && event?.window === button.window ? event.map { button.convert($0.locationInWindow, from: nil) } : nil
        }
        guard let region = Self.region(at: point, imageRect: button.cell?.imageRect(forBounds: button.bounds) ?? .zero,
            collectionVisible: collectionVisible, secondary: event?.type == .rightMouseDown || event?.type == .rightMouseUp,
            commandDrag: isMouse && (event?.modifierFlags.contains(.command) == true || NSEvent.modifierFlags.contains(.command))) else { return }
        ArcKitLog.append("menu-bar combined-entry action=\(region == .collection ? "collection" : "menu") native=\(button is NSStatusBarButton) local=\(point.map(NSStringFromPoint) ?? "none") event=\(event?.type.rawValue ?? 0)")
        perform(region)
    }

    private func menuBarHitFrame(_ frame: CGRect) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
        // 系统把整个菜单栏高度作为热区，代理按钮自身可能只有22pt；包含其上下内边距。
        let height = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let accessible = button.accessibilityFrame()
        let horizontal = accessible.contains(frame) ? accessible : frame
        return CGRect(x: horizontal.minX, y: screen.frame.maxY - height, width: horizontal.width, height: height)
    }

    static func localPoint(pointer: CGPoint, screenFrame: CGRect, bounds: CGRect, hitFrame: CGRect? = nil) -> CGPoint? {
        guard screenFrame.width > 0, screenFrame.height > 0, (hitFrame ?? screenFrame).contains(pointer),
              abs(screenFrame.width - bounds.width) < 1, abs(screenFrame.height - bounds.height) < 1 else { return nil }
        return CGPoint(x: pointer.x - screenFrame.minX + bounds.minX, y: pointer.y - screenFrame.minY + bounds.minY)
    }

    /// 只清理已退役的自有开关记录，品牌和用户图标的位置不动。
    static func removeRetiredPosition(owner: String) {
        guard #available(macOS 27.0, *) else { return }
        let domain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar").path as CFString
        let key = "TrailingItemPreferredPositions" as CFString
        guard CFPreferencesAppSynchronize(domain), var positions = CFPreferencesCopyAppValue(key, domain) as? [String: Double],
              positions.removeValue(forKey: "status:\(owner)::menu-bar.collection-toggle") != nil else { return }
        CFPreferencesSetAppValue(key, positions as CFDictionary, domain)
        if !CFPreferencesAppSynchronize(domain) { ArcKitLog.append("menu-bar retired toggle position cleanup unconfirmed") }
    }
}
