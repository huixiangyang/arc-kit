import ArcKitPlatform
import AppKit

/// 分区只管理 Arc Kit 自己创建的状态项，不改第三方应用的配置或合成拖拽输入。
@MainActor
protocol MenuBarPartitionDriving: AnyObject {
    var onRequest: ((MenuBarPresentation) -> Void)? { get set }
    var onOpenShelf: ((MenuBarShelfScope) -> Void)? { get set }
    func install(deepSectionEnabled: Bool)
    func present(_ state: MenuBarPresentation) async throws
    func remove()
    func refreshLabels()
    func revealAll()
    func confirmRevealedLayout() async throws
    func layoutSnapshot() throws -> MenuBarPartitionSnapshot
}

enum MenuBarPartitionError: Error, LocalizedError {
    case invalidOrder, unavailable, layoutUnconfirmed, recoveryUnconfirmed, systemOverflowSections, overflowDisplayChanged
    var errorDescription: String? {
        switch self {
        case .invalidOrder: L10n.string(.MenuBar.runtimeInvalidOrder)
        case .unavailable: L10n.string(.MenuBar.runtimeUnavailable)
        case .layoutUnconfirmed: L10n.string(.MenuBar.runtimeLayoutUnconfirmed)
        case .recoveryUnconfirmed: L10n.string(.MenuBar.runtimeRecoveryUnconfirmed)
        case .systemOverflowSections: L10n.string(.MenuBar.overflowSectionsUnavailable)
        case .overflowDisplayChanged: L10n.string(.MenuBar.overflowDisplayChanged)
        }
    }
}

@MainActor
final class NativeMenuBarPartitions: NSObject, MenuBarPartitionDriving {
    var onRequest: ((MenuBarPresentation) -> Void)?
    var onOpenShelf: ((MenuBarShelfScope) -> Void)?
    private var toggleItem: NSStatusItem?
    private var hiddenDivider: NSStatusItem?
    private var deepDivider: NSStatusItem?
    private var presentation: MenuBarPresentation = .all
    private let expandedLength: CGFloat = 18
    private var generation = 0
    private let namespace: String
    private let savesPositions: Bool
    private let mode: MenuBarPartitionMode
    private var overflowSpacers: [NSStatusItem] = []

    init(namespace: String = "menu-bar", savesPositions: Bool = true, mode: MenuBarPartitionMode = .current) {
        self.namespace = namespace
        self.savesPositions = savesPositions
        self.mode = mode
        super.init()
    }

    func install(deepSectionEnabled: Bool) {
        generation &+= 1
        if toggleItem == nil {
            // 系统保存这些自有状态项的位置；SQLite 不复制 WindowServer 的排列状态。
            toggleItem = makeItem(name: "menu-bar.toggle", icon: .chevronDown, title: L10n.string(.MenuBar.runtimeToggle))
            toggleItem?.button?.target = self
            toggleItem?.button?.action = #selector(toggle(_:))
            toggleItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if mode == .systemOverflow, let screens = MenuBarScreenSnapshot.capture(),
               let plan = try? MenuBarOverflowPlan(displays: screens.displays) {
                // 占位在分隔线右侧；图标只需放到可见分隔线左侧，不必穿过一组不可见控件。
                overflowSpacers = (1..<plan.segmentCount).map { index in
                    makeItem(name: "menu-bar.overflow.spacer.\(index)", icon: nil, title: "", length: 0)
                }
            }
            hiddenDivider = makeItem(name: "menu-bar.hidden", icon: .moveHorizontal, title: L10n.string(.MenuBar.groupHidden))
            hiddenDivider?.button?.target = self
            hiddenDivider?.button?.action = #selector(reveal(_:))
        }
        if deepSectionEnabled, mode.supportsSections, deepDivider == nil {
            deepDivider = makeItem(name: "menu-bar.deep", icon: .eyeOff, title: L10n.string(.MenuBar.groupDeep))
            deepDivider?.button?.target = self
            deepDivider?.button?.action = #selector(reveal(_:))
        } else if !deepSectionEnabled || !mode.supportsSections, let item = deepDivider {
            item.length = expandedLength
            if !savesPositions { item.autosaveName = nil }
            NSStatusBar.system.removeStatusItem(item)
            deepDivider = nil
        }
        // 安装及分区配置变化均先展示全部，不在首次启用时突然收起现有图标。
        expandAll()
        refreshLabels()
    }

    func present(_ state: MenuBarPresentation) async throws {
        try Task.checkCancellation()
        guard let hiddenDivider, let toggleItem else { throw MenuBarPartitionError.unavailable }
        generation &+= 1
        let request = generation
        if state == .all { revealAll(); return }
        if mode == .systemOverflow {
            guard state == .collapsed else { throw MenuBarPartitionError.systemOverflowSections }
            try await collapseIntoSystemOverflow(request: request)
            return
        }
        if state == presentation { return }
        // 普通展开先缩小占位，不以原离屏框回读为前提；新增收起先校验可见边界。
        // 变更后统一确认完整布局；独立的显示全部入口始终不依赖坐标回读。
        try await Task.sleep(for: .milliseconds(120))
        try Task.checkCancellation()
        guard request == generation, self.hiddenDivider === hiddenDivider, self.toggleItem === toggleItem else { throw CancellationError() }
        guard let screens = MenuBarScreenSnapshot.capture() else { throw MenuBarPartitionError.unavailable }
        let wasCollapsed = presentation == .collapsed
        if !wasCollapsed { try await confirmLayout(nil, screens: screens, request: request) }
        // 一屏宽度已足以把左侧内容移出目标屏幕；翻倍会触发部分系统的 5000pt 裁剪。
        let width = (screens.displays.map(\.frame.width).max() ?? 0) + 100
        let previous = presentation
        let previousHiddenLength = hiddenDivider.length
        let previousDeepLength = deepDivider?.length
        hiddenDivider.button?.image = state == .collapsed ? nil : image(.moveHorizontal)
        hiddenDivider.length = state == .collapsed ? width : expandedLength
        // 从收起到普通展开时不动深度分隔线，避免短暂暴露深度区。
        if !wasCollapsed { deepDivider?.button?.image = nil; deepDivider?.length = width }
        do {
            try await confirmLayout(state, screens: screens, request: request)
            presentation = state
            toggleItem.button?.image = image(state == .collapsed ? .chevronRight : .chevronDown)
        } catch {
            // 只有本次请求仍拥有控件时才回退，不能覆盖更晚的显示全部、停用或安装。
            if request == generation {
                hiddenDivider.length = previousHiddenLength
                hiddenDivider.button?.image = previous == .collapsed ? nil : image(.moveHorizontal)
                if let previousDeepLength {
                    deepDivider?.length = previousDeepLength
                    deepDivider?.button?.image = previous == .all ? image(.eyeOff) : nil
                }
            }
            throw error
        }
    }

    private func collapseIntoSystemOverflow(request: Int) async throws {
        guard let hiddenDivider, let screens = MenuBarScreenSnapshot.capture() else { throw MenuBarPartitionError.unavailable }
        let plan = try MenuBarOverflowPlan(displays: screens.displays)
        let items = overflowSpacers + [hiddenDivider]
        // 新屏幕需要更多分段时不能把新占位插在用户图标左侧；要求重新启用以重建完整分组。
        guard items.count >= plan.segmentCount else { throw MenuBarPartitionError.overflowDisplayChanged }
        for item in items { item.length = plan.segmentLength; item.button?.image = nil }
        do {
            var matched = false
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                guard request == generation else { throw CancellationError() }
                guard MenuBarScreenSnapshot.capture() == screens else { throw MenuBarPartitionError.layoutUnconfirmed }
                let current = items.allSatisfy { item in
                    guard let button = item.button else { return false }
                    return abs(button.bounds.width - plan.segmentLength) <= 1
                }
                if matched && current {
                    // 这里只确认自有占位已应用，不伪造系统溢出项目的负坐标或深度分组。
                    presentation = .collapsed
                    toggleItem?.button?.image = image(.chevronRight)
                    return
                }
                matched = current
            }
            throw MenuBarPartitionError.layoutUnconfirmed
        } catch {
            if request == generation { expandAll() }
            throw error
        }
    }

    private func confirmLayout(_ state: MenuBarPresentation?, screens: MenuBarScreenSnapshot, request: Int) async throws {
        var previous: MenuBarPartitionSnapshot?
        var failure: Error = MenuBarPartitionError.layoutUnconfirmed
        // 原生代理异步布局，连续两次一致才提交状态；只重读，不重发收起请求。
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            guard MenuBarScreenSnapshot.capture() == screens else { throw MenuBarPartitionError.layoutUnconfirmed }
            do {
                let current = try state == nil ? validateExpandedBoundary(screens: screens) : layoutSnapshot()
                if current == previous, state.map({ current.confirmsHiddenSections(for: $0) }) ?? true { return }
                previous = current
            } catch {
                previous = nil
                if state == nil { failure = error }
            }
        }
        throw failure
    }

    private func validateExpandedBoundary(screens: MenuBarScreenSnapshot) throws -> MenuBarPartitionSnapshot {
        guard let toggleItem, let hiddenDivider,
              let control = frame(of: toggleItem, screens: screens), let hidden = frame(of: hiddenDivider, screens: screens) else {
            throw MenuBarPartitionError.unavailable
        }
        let visibleDeep: CGRect?
        if let deepDivider, deepDivider.length == expandedLength {
            guard let rect = frame(of: deepDivider, screens: screens) else { throw MenuBarPartitionError.unavailable }
            visibleDeep = rect
        } else { visibleDeep = nil }
        // 这里只验证即将新增的收起动作，不向分区筛选返回省略深度边界的凭据。
        return try MenuBarPartitionSnapshot(generation: generation, displays: screens.displays,
            control: control, hidden: hidden, deep: visibleDeep)
    }

    func remove() {
        generation &+= 1
        expandAll()
        // 先释放大占位，再删除控件；退出或关闭功能必须让系统恢复原生可见性计算。
        for item in overflowSpacers + [deepDivider, hiddenDivider, toggleItem].compactMap({ $0 }) {
            if !savesPositions { item.autosaveName = nil }
            NSStatusBar.system.removeStatusItem(item)
        }
        deepDivider = nil; hiddenDivider = nil; toggleItem = nil
        overflowSpacers.removeAll()
    }

    func revealAll() {
        generation &+= 1
        expandAll()
    }

    func confirmRevealedLayout() async throws {
        guard let toggleItem, let hiddenDivider, presentation == .all else { throw MenuBarPartitionError.unavailable }
        let request = generation
        let items = [toggleItem, hiddenDivider] + [deepDivider].compactMap { $0 } + overflowSpacers
        let expectedWidths = items.map(\.length)
        var confirmation = MenuBarRevealConfirmation()
        // 屏幕切换时 AppKit 与 WindowServer 可能短暂不一致。只等待并回读，不重新发送恢复动作。
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard request == generation, presentation == .all,
                  self.toggleItem === toggleItem, self.hiddenDivider === hiddenDivider else { throw CancellationError() }
            if confirmation.observe(displays: MenuBarScreenSnapshot.capture()?.displays,
                                    expectedWidths: expectedWidths, actualWidths: items.map { $0.button?.bounds.width }) {
                // 只确认屏幕与自有占位稳定，不将其解释为每块屏幕的第三方菜单已恢复。
                return
            }
        }
        throw MenuBarPartitionError.recoveryUnconfirmed
    }

    private func expandAll() {
        for item in overflowSpacers { item.length = 0 }
        hiddenDivider?.length = expandedLength
        hiddenDivider?.button?.image = image(.moveHorizontal)
        deepDivider?.length = expandedLength
        deepDivider?.button?.image = image(.eyeOff)
        toggleItem?.button?.image = image(.chevronDown)
        presentation = .all
    }

    private func image(_ name: ArcIconName) -> NSImage {
        let image = ArcIconImage.image(name)
        image.size = NSSize(width: 14, height: 14)
        return image
    }

    private func makeItem(name: String, icon: ArcIconName?, title: String, length: CGFloat = 18) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        let identifier = name.replacingOccurrences(of: "menu-bar", with: namespace)
        // 不设置名称时 AppKit 会自动选名；临时检查也必须显式使用唯一名称，撤除时清除。
        item.autosaveName = NSStatusItem.AutosaveName(identifier)
        // 启用意图优先于 macOS 为同名自有项目保存的旧隐藏状态，避免失去恢复入口。
        item.isVisible = true
        item.button?.image = icon.map(image)
        item.button?.setAccessibilityIdentifier(identifier)
        item.button?.setAccessibilityLabel(title)
        item.button?.toolTip = title
        return item
    }

    func layoutSnapshot() throws -> MenuBarPartitionSnapshot {
        guard mode.supportsSections else { throw MenuBarPartitionError.systemOverflowSections }
        guard let toggleItem, let hiddenDivider, let screens = MenuBarScreenSnapshot.capture(),
              let control = frame(of: toggleItem, screens: screens),
              let hidden = frame(of: hiddenDivider, screens: screens) else { throw MenuBarPartitionError.unavailable }
        let deep: CGRect?
        if let deepDivider {
            guard let rect = frame(of: deepDivider, screens: screens) else { throw MenuBarPartitionError.unavailable }
            deep = rect
        } else { deep = nil }
        return try .init(generation: generation, displays: screens.displays, control: control, hidden: hidden, deep: deep)
    }

    private func frame(of item: NSStatusItem, screens: MenuBarScreenSnapshot) -> CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let frame = screens.coordinates.appKitToAccessibility(window.convertToScreen(button.convert(button.bounds, to: nil)))
        // 宽占位允许离屏，但必须读取到与当前请求一致的原生宽度，不能把布局中的旧窄框当边界。
        guard frame.isFiniteAndPositive, abs(frame.width - item.length) <= 1 else { return nil }
        return frame
    }

    #if DEBUG
    /// 有界实机检查直接测量系统长度响应，不经过正式分区校验；不用于产品运行。
    func nativeCheckSetSpacerLength(_ length: CGFloat) {
        generation &+= 1
        hiddenDivider?.length = length
        hiddenDivider?.button?.image = length == expandedLength ? image(.moveHorizontal) : nil
    }

    /// 同时保留未经校验的系统读数与正式凭据结果，不能用请求值冒充系统布局。
    func nativeCheckReadings() -> [[String: Any]] {
        let items = [("control", toggleItem), ("hidden", hiddenDivider), ("deep", deepDivider)] + overflowSpacers.enumerated().map { ("spacer.\($0.offset)", Optional($0.element)) }
        return items.compactMap { name, item in
            guard let item else { return nil }
            var value: [String: Any] = ["name": name, "requestedLength": item.length, "isVisible": item.isVisible]
            if let button = item.button {
                value["buttonBounds"] = NSStringFromRect(button.bounds)
                if let window = button.window {
                    value["windowID"] = window.windowNumber
                    value["windowFrame"] = NSStringFromRect(window.frame)
                    value["screenFrame"] = NSStringFromRect(window.convertToScreen(button.convert(button.bounds, to: nil)))
                }
            }
            if let screens = MenuBarScreenSnapshot.capture(), let frame = frame(of: item, screens: screens) {
                value["validatedAXFrame"] = NSStringFromRect(frame)
            }
            return value
        }
    }
    #endif

    func refreshLabels() {
        for (item, title) in [(toggleItem, L10n.string(.MenuBar.runtimeToggle)),
                              (hiddenDivider, L10n.string(.MenuBar.groupHidden)),
                              (deepDivider, L10n.string(.MenuBar.groupDeep))] {
            item?.button?.toolTip = title
            item?.button?.setAccessibilityLabel(title)
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            let shelf = NSMenuItem(title: L10n.string(.MenuBar.shelfOpen), action: #selector(openShelf(_:)), keyEquivalent: "")
            shelf.target = self
            let collection = NSMenuItem(title: L10n.string(.MenuBar.scopeOpenCollected), action: #selector(openCollected(_:)), keyEquivalent: "")
            collection.target = self
            if mode.supportsSections { menu.addItem(collection) }
            menu.addItem(shelf)
            menu.addItem(.separator())
            for state in mode.presentations {
                let item = NSMenuItem(title: state.title, action: #selector(selectPresentation(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state.rawValue
                menu.addItem(item)
            }
            if let button = toggleItem?.button { NSMenu.popUpContextMenu(menu, with: event, for: button) }
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onRequest?(.all)
        } else {
            onRequest?(presentation == .collapsed ? (mode.supportsSections ? .expanded : .all) : .collapsed)
        }
    }
    @objc private func openShelf(_ sender: Any?) { onOpenShelf?(.all) }
    @objc private func openCollected(_ sender: Any?) { onOpenShelf?(.collected) }
    @objc private func reveal(_ sender: Any?) { onRequest?(.all) }
    @objc private func selectPresentation(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let state = MenuBarPresentation(rawValue: value) else { return }
        onRequest?(state)
    }
}

/// 连续两次有效读数才结束恢复等待；缺失按钮、旧宽度或屏幕变化都会重新计数。
struct MenuBarRevealConfirmation {
    private var previousDisplays: [MenuBarDisplay]?

    mutating func observe(displays: [MenuBarDisplay]?, expectedWidths: [CGFloat], actualWidths: [CGFloat?]) -> Bool {
        guard let displays, !displays.isEmpty, !expectedWidths.isEmpty, expectedWidths.count == actualWidths.count,
              zip(expectedWidths, actualWidths).allSatisfy({ expected, actual in
                  guard expected.isFinite, expected >= 0, let actual, actual.isFinite else { return false }
                  return abs(expected - actual) <= 1
              }) else {
            previousDisplays = nil
            return false
        }
        let confirmed = previousDisplays == displays
        previousDisplays = displays
        return confirmed
    }
}
