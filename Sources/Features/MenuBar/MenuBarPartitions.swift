import ArcKitPlatform
import AppKit

/// 原生分区保留排列锚点；macOS 27 通过带恢复清单的系统允许状态收纳，不合成拖拽输入。
@MainActor
protocol MenuBarPartitionDriving: AnyObject {
    var recoveryFailure: Error? { get }
    func setCollectedApplications(_ bundles: Set<String>)
    func install(deepSectionEnabled: Bool)
    func present(_ state: MenuBarPresentation) async throws
    func remove()
    func refreshLabels()
    func revealAll()
    func confirmRevealedLayout() async throws
    func layoutSnapshot() throws -> MenuBarPartitionSnapshot
}

extension MenuBarPartitionDriving {
    var recoveryFailure: Error? { nil }
    func setCollectedApplications(_ bundles: Set<String>) {}
}

enum MenuBarPartitionError: Error, LocalizedError {
    case invalidOrder, unavailable, layoutUnconfirmed, recoveryUnconfirmed, systemVisibilitySections, overflowCapacity, overflowOrderUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidOrder: L10n.string(.MenuBar.runtimeInvalidOrder)
        case .unavailable: L10n.string(.MenuBar.runtimeUnavailable)
        case .layoutUnconfirmed: L10n.string(.MenuBar.runtimeLayoutUnconfirmed)
        case .recoveryUnconfirmed: L10n.string(.MenuBar.runtimeRecoveryUnconfirmed)
        case .systemVisibilitySections: L10n.string(.MenuBar.overflowSectionsUnavailable)
        case .overflowCapacity: L10n.string(.MenuBar.overflowCapacity)
        case .overflowOrderUnavailable: L10n.string(.MenuBar.overflowOrderUnavailable)
        }
    }
}

@MainActor
final class NativeMenuBarPartitions: MenuBarPartitionDriving {
    private var installed = false
    private var collectedApplications = Set<String>()
    private var controlAnchor: NSStatusItem?
    private var collectionAnchor: NSStatusItem?
    private var deepAnchor: NSStatusItem?
    /// 自有宽度的已提交意图；对外成功仍由连续回读确认。
    private var appliedPresentation: MenuBarPresentation = .all
    private var confirmedPresentation: MenuBarPresentation = .all
    private var pendingPresentation: MenuBarPresentation?
    private let trace: (String) -> Void
    private var expandedLength: CGFloat { mode == .systemVisibility ? 10000 : 1 }
    private var generation = 0
    private let namespace: String
    private let savesPositions: Bool
    private let mode: MenuBarPartitionMode
    private let visibility = MenuBarVisibilitySession()
    private var visibilityRecoveryError: Error?
    var recoveryFailure: Error? { visibilityRecoveryError }

    init(namespace: String? = nil, savesPositions: Bool = true, mode: MenuBarPartitionMode = .current,
         trace: @escaping (String) -> Void = { ArcKitLog.append($0) }) {
        // 新命名空间隔离旧版散落槽位；旧系统的已有分区位置保持原契约。
        self.namespace = namespace ?? (mode == .systemVisibility ? "menu-bar.group-v3" : "menu-bar")
        self.trace = trace
        self.savesPositions = savesPositions
        self.mode = mode
    }

    func setCollectedApplications(_ bundles: Set<String>) { collectedApplications = bundles }

    func install(deepSectionEnabled: Bool) {
        generation &+= 1
        installed = true
        // 直接隐藏不再注册分界锚点，Cmd拖动只影响系统顺序。
        if mode == .systemVisibility { expandAll(); return }
        if controlAnchor == nil {
            // 系统保存这些自有状态项的位置；SQLite 不复制 WindowServer 的排列状态。
            controlAnchor = makeItem(name: "menu-bar.toggle", length: expandedLength)
            collectionAnchor = makeItem(name: "menu-bar.hidden", length: expandedLength)
        }
        if deepSectionEnabled, mode.supportsSections, deepAnchor == nil {
            deepAnchor = makeItem(name: "menu-bar.deep", length: expandedLength)
        } else if !deepSectionEnabled || !mode.supportsSections, let item = deepAnchor {
            item.length = expandedLength
            if !savesPositions { item.autosaveName = nil }
            NSStatusBar.system.removeStatusItem(item)
            deepAnchor = nil
        }
        // 安装及分区配置变化均先展示全部，不在首次启用时突然收起现有图标。
        expandAll()
        refreshLabels()
    }

    func present(_ state: MenuBarPresentation) async throws {
        try Task.checkCancellation()
        guard installed else { throw MenuBarPartitionError.unavailable }
        generation &+= 1
        let request = generation
        if state == .all { revealAll(); return }
        if state == confirmedPresentation && state == appliedPresentation {
            pendingPresentation = nil
            refreshAnchors()
            return
        }
        pendingPresentation = state
        refreshAnchors()
        trace("menu-bar begin generation=\(request) target=\(state.rawValue)")
        defer {
            if generation == request { pendingPresentation = nil; refreshAnchors() }
        }
        if mode == .systemVisibility {
            guard state == .collapsed else { throw MenuBarPartitionError.systemVisibilitySections }
            try await collapseUsingVisibility(request: request)
            return
        }
        guard let collectionAnchor, let controlAnchor else { throw MenuBarPartitionError.unavailable }
        // 普通展开先缩小占位，不以原离屏框回读为前提；新增收起先校验可见边界。
        // 变更后统一确认完整布局；独立的显示全部入口始终不依赖坐标回读。
        try await Task.sleep(for: .milliseconds(120))
        try Task.checkCancellation()
        guard request == generation, self.collectionAnchor === collectionAnchor, self.controlAnchor === controlAnchor else { throw CancellationError() }
        guard let screens = MenuBarScreenSnapshot.capture() else { throw MenuBarPartitionError.unavailable }
        let wasCollapsed = appliedPresentation == .collapsed
        if !wasCollapsed { try await confirmLayout(nil, screens: screens, request: request) }
        // 一屏宽度已足以把左侧内容移出目标屏幕；翻倍会触发部分系统的 5000pt 裁剪。
        let width = (screens.displays.map(\.frame.width).max() ?? 0) + 100
        let previous = appliedPresentation
        let previousConfirmed = confirmedPresentation
        let previousHiddenLength = collectionAnchor.length
        let previousDeepLength = deepAnchor?.length
        collectionAnchor.length = state == .collapsed ? width : expandedLength
        // 从收起到普通展开时不动深度分隔线，避免短暂暴露深度区。
        if !wasCollapsed { deepAnchor?.button?.image = nil; deepAnchor?.length = width }
        // 旧请求可能尚未确认。后续切换必须依据已写入的宽度意图，不能误用上次确认状态。
        appliedPresentation = state
        refreshAnchors()
        do {
            try await confirmLayout(state, screens: screens, request: request)
            confirmedPresentation = state
            refreshAnchors()
        } catch {
            // 只有本次请求仍拥有控件时才回退，不能覆盖更晚的显示全部、停用或安装。
            if request == generation {
                appliedPresentation = previous
                confirmedPresentation = previousConfirmed
                collectionAnchor.length = previousHiddenLength
                if let previousDeepLength {
                    deepAnchor?.length = previousDeepLength
                    deepAnchor?.button?.image = nil
                }
                refreshAnchors()
            }
            throw error
        }
    }

    private func collapseUsingVisibility(request: Int) async throws {
        do {
            try visibility.conceal(collectedApplications: collectedApplications,
                owner: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            appliedPresentation = .collapsed; confirmedPresentation = .collapsed
            visibilityRecoveryError = nil
            trace("menu-bar visibility-committed generation=\(request)")
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
        guard let controlAnchor, let collectionAnchor,
              let control = frame(of: controlAnchor, screens: screens), let hidden = frame(of: collectionAnchor, screens: screens) else {
            throw MenuBarPartitionError.unavailable
        }
        let visibleDeep: CGRect?
        if let deepAnchor, deepAnchor.length == expandedLength {
            guard let rect = frame(of: deepAnchor, screens: screens) else { throw MenuBarPartitionError.unavailable }
            visibleDeep = rect
        } else { visibleDeep = nil }
        // 这里只验证即将新增的收起动作，不向分区筛选返回省略深度边界的凭据。
        return try MenuBarPartitionSnapshot(generation: generation, displays: screens.displays,
            control: control, hidden: hidden, deep: visibleDeep)
    }

    func remove() {
        installed = false
        generation &+= 1
        expandAll()
        // 先释放大占位，再删除控件；退出或关闭功能必须让系统恢复原生可见性计算。
        for item in [deepAnchor, collectionAnchor, controlAnchor].compactMap({ $0 }) {
            if !savesPositions { item.autosaveName = nil }
            NSStatusBar.system.removeStatusItem(item)
        }
        deepAnchor = nil; collectionAnchor = nil; controlAnchor = nil
    }

    func revealAll() {
        generation &+= 1
        expandAll(recoverOrphans: true)
    }

    func confirmRevealedLayout() async throws {
        guard installed, appliedPresentation == .all else { throw MenuBarPartitionError.unavailable }
        if let visibilityRecoveryError { throw visibilityRecoveryError }
        let request = generation
        if mode == .systemVisibility {
            var confirmation = MenuBarRevealConfirmation()
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation()
                guard request == generation, appliedPresentation == .all else { throw CancellationError() }
                if confirmation.observe(displays: MenuBarScreenSnapshot.capture()?.displays, released: visibilityRecoveryError == nil) { return }
            }
            throw MenuBarPartitionError.recoveryUnconfirmed
        }
        guard let controlAnchor, let collectionAnchor else { throw MenuBarPartitionError.unavailable }
        // 超宽占位被系统排除；恢复检查正常锚点，以及整组槽位已退出有效占宽范围。
        let items = [controlAnchor, collectionAnchor] + [deepAnchor].compactMap { $0 }
        let expectedWidths = items.map(\.length)
        var confirmation = MenuBarRevealConfirmation()
        // 屏幕切换时 AppKit 与 WindowServer 可能短暂不一致。只等待并回读，不重新发送恢复动作。
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard request == generation, appliedPresentation == .all,
                  self.controlAnchor === controlAnchor, self.collectionAnchor === collectionAnchor else { throw CancellationError() }
            let confirmed = confirmation.observe(displays: MenuBarScreenSnapshot.capture()?.displays,
                expectedWidths: expectedWidths, actualWidths: items.map { $0.button?.bounds.width })
            if confirmed {
                // 只确认屏幕与自有占位稳定，不将其解释为每块屏幕的第三方菜单已恢复。
                return
            }
        }
        throw MenuBarPartitionError.recoveryUnconfirmed
    }

    private func expandAll(recoverOrphans: Bool = false) {
        if mode == .systemVisibility {
            do { try visibility.reveal(recoverOrphans: recoverOrphans); visibilityRecoveryError = nil }
            catch { visibilityRecoveryError = error; trace("menu-bar visibility recovery failed: \(error.localizedDescription)") }
        }
        collectionAnchor?.length = expandedLength
        deepAnchor?.length = expandedLength
        appliedPresentation = .all
        confirmedPresentation = .all
        pendingPresentation = nil
        refreshAnchors()
    }

    private func makeItem(name: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        let identifier = name.replacingOccurrences(of: "menu-bar", with: namespace)
        item.autosaveName = NSStatusItem.AutosaveName(identifier)
        item.isVisible = true
        if let button = item.button {
            button.setAccessibilityIdentifier(identifier)
            MenuBarControlAppearance.concealAnchor(button)
        }
        return item
    }

    func layoutSnapshot() throws -> MenuBarPartitionSnapshot {
        guard mode.supportsSections else { throw MenuBarPartitionError.systemVisibilitySections }
        guard let controlAnchor, let collectionAnchor, let screens = MenuBarScreenSnapshot.capture(),
              let control = frame(of: controlAnchor, screens: screens),
              let hidden = frame(of: collectionAnchor, screens: screens) else { throw MenuBarPartitionError.unavailable }
        let deep: CGRect?
        if let deepAnchor {
            guard let rect = frame(of: deepAnchor, screens: screens) else { throw MenuBarPartitionError.unavailable }
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
    var nativeCheckExpandedLength: CGFloat { expandedLength }

    func nativeCheckSetSpacerLength(_ length: CGFloat) {
        generation &+= 1
        collectionAnchor?.length = length
        appliedPresentation = length == expandedLength ? .all : .collapsed
        refreshAnchors()
    }

    /// 同时保留未经校验的系统读数与正式凭据结果，不能用请求值冒充系统布局。
    func nativeCheckReadings() -> [[String: Any]] {
        let items = [("control", controlAnchor), ("hidden", collectionAnchor), ("deep", deepAnchor)]
        return items.compactMap { name, item in
            guard let item else { return nil }
            var value: [String: Any] = ["name": name, "requestedLength": item.length, "isVisible": item.isVisible,
                "appliedPresentation": appliedPresentation.rawValue, "confirmedPresentation": confirmedPresentation.rawValue,
                "pendingPresentation": pendingPresentation?.rawValue ?? "none"]
            if let button = item.button {
                value["buttonBounds"] = NSStringFromRect(button.bounds)
                value["buttonTitle"] = button.title
                value["hasImage"] = button.image != nil
                value["actionable"] = button.isEnabled && button.action != nil
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

    func refreshLabels() { refreshAnchors() }

    private func refreshAnchors() {
        // 分界只保留系统排列身份，所有操作集中到 Arc Kit 原有图标的快捷面板。
        for item in [controlAnchor, collectionAnchor, deepAnchor].compactMap({ $0 }) {
            if let button = item.button { MenuBarControlAppearance.concealAnchor(button) }
        }
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
        return observe(displays: displays, released: true)
    }

    mutating func observe(displays: [MenuBarDisplay]?, released: Bool) -> Bool {
        guard released, let displays, !displays.isEmpty else { previousDisplays = nil; return false }
        let confirmed = previousDisplays == displays
        previousDisplays = displays
        return confirmed
    }
}
