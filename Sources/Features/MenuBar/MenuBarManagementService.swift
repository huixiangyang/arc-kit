import ArcKitPlatform
import AppKit
import Combine

enum MenuBarEnvironmentState: Equatable {
    case ready, settling, sleeping, unconfirmed

    var status: String? {
        switch self {
        case .settling: L10n.string(.MenuBar.runtimeEnvironmentSettling)
        case .sleeping: L10n.string(.MenuBar.runtimeEnvironmentSleeping)
        case .ready, .unconfirmed: nil
        }
    }
}

enum MenuBarEnvironmentChange: Equatable, Sendable {
    case layout, sleep, wake
}

/// 与应用同生命周期的状态项管理。只有已提交配置可以创建、更新或释放原生控件。
/// 调试模式不构造 native driver，即使预览开关开启也不能接触系统菜单栏。
@MainActor
final class MenuBarManagementService: ObservableObject {
    @Published private(set) var isEnabled = false {
        didSet { if isEnabled != oldValue { resetAutoCollapse() } }
    }
    @Published private(set) var requestedPresentation: MenuBarPresentation = .all {
        didSet { resetAutoCollapse() }
    }
    @Published private(set) var message: String?
    @Published private(set) var lastActionReceipt: String?
    @Published private(set) var environmentState: MenuBarEnvironmentState = .ready {
        didSet { resetAutoCollapse() }
    }
    let shelfModel = MenuBarShelfModel()
    let managementModel = MenuBarShelfModel()
    let arrangementModel: MenuBarArrangementModel
    private enum ItemOwner: Equatable {
        case shelf(UUID), management(UUID)
        var isShelf: Bool { if case .shelf = self { return true }; return false }
    }
    private var itemOwner: ItemOwner?
    private var managementOwner: UUID?
    @Published private(set) var hotKeyFailures: [MenuBarHotKeyAction: Int32] = [:]
    @Published private(set) var registeredHotKeyActions: Set<MenuBarHotKeyAction> = []
    @Published private(set) var isRecordingShortcut = false
    let isPreview: Bool
    let partitionMode: MenuBarPartitionMode
    private let driverFactory: () -> any MenuBarPartitionDriving
    private var driver: (any MenuBarPartitionDriving)?
    private var settings: MenuBarSettings?
    private var observations: [AnyCancellable] = []
    private var presentationTask: Task<Void, Never>?
    @Published private(set) var pendingPresentation: MenuBarPresentation?
    private var requestID = UUID()
    private var autoCollapseRequestID: UUID?
    private var environmentTask: Task<Void, Never>?
    private var environmentRequestID = UUID()
    private var isSleeping = false
    private let captureInventory: (MenuBarItemAccessSession) async throws -> MenuBarInventory
    private let accessSessionFactory: () -> MenuBarItemAccessSession
    private let currentDisplayID: () -> UInt32?
    private let shelfPanelFactory: (MenuBarShelfModel, MenuBarShelfActions) -> any MenuBarShelfPresenting
    private var isActive = true
    private let workspaceNotifications: NotificationCenter
    private let applicationNotifications: NotificationCenter
    private let hotKeyFactory: () -> any MenuBarHotKeyDriving
    private var hotKeys: (any MenuBarHotKeyDriving)?
    private var shortcutRecorders = Set<UUID>()
    private var itemAccess: MenuBarItemAccessSession?
    private var shelfPanel: (any MenuBarShelfPresenting)?
    private var itemTask: Task<Void, Never>?
    private var itemRequestID = UUID()
    private var panelDisplayID: UInt32?
    private var isActivatingItem = false
    private let uptime: () -> TimeInterval
    private let inputIdleTime: () -> TimeInterval
    private let idleTicks: () -> AnyPublisher<Void, Never>
    private var autoCollapseObservation: AnyCancellable?
    private var autoCollapseNotBefore: TimeInterval = 0

    var canSearchAllIcons: Bool { !isPreview && isActive && !isSleeping }
    var needsCollectionSelection: Bool { partitionMode == .systemVisibility && settings?.collectedApplications.isEmpty == true }
    var requestCollectionSetup: (() -> Void)?

    init(isPreview: Bool = false, partitionMode: MenuBarPartitionMode = .current,
         arrangementModel: MenuBarArrangementModel? = nil, collectionAccess: MenuBarCollectionAccess? = nil,
         driverFactory: (() -> any MenuBarPartitionDriving)? = nil,
         hotKeyFactory: @escaping () -> any MenuBarHotKeyDriving = { NativeMenuBarHotKeys() },
         captureInventory: @escaping (MenuBarItemAccessSession) async throws -> MenuBarInventory = { try await MenuBarInspector().captureForInteraction(session: $0) },
         accessSessionFactory: @escaping () -> MenuBarItemAccessSession = { MenuBarItemAccessSession() },
         currentDisplayID: @escaping () -> UInt32? = {
             let screens = NSScreen.screens.filter { $0.frame.contains(NSEvent.mouseLocation) }
             guard screens.count == 1 else { return nil }
             return (screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
         },
         shelfPanelFactory: @escaping (MenuBarShelfModel, MenuBarShelfActions) -> any MenuBarShelfPresenting = { model, actions in
             MenuBarShelfPanel(model: model, refresh: actions.refresh, openPermission: actions.openPermission, showAll: actions.showAll)
         },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         inputIdleTime: @escaping () -> TimeInterval = {
             // 只读取当前登录会话的输入空闲时长，不监听按键内容，也不注册事件拦截。
             // kCGAnyInputEventType 的 C 宏不导出到 Swift，对应 UInt32.max。
             CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: .max)!)
         },
         idleTicks: @escaping () -> AnyPublisher<Void, Never> = {
             Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .default)
                 .autoconnect().map { _ in () }.eraseToAnyPublisher()
         },
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationNotifications: NotificationCenter = .default) {
        self.isPreview = isPreview
        self.arrangementModel = arrangementModel ?? MenuBarArrangementModel(collection: collectionAccess ?? (isPreview ? .preview() : .unavailable), isPreview: isPreview)
        self.partitionMode = partitionMode
        self.driverFactory = driverFactory ?? { NativeMenuBarPartitions(mode: partitionMode) }
        self.hotKeyFactory = hotKeyFactory
        self.captureInventory = captureInventory
        self.accessSessionFactory = accessSessionFactory
        self.shelfPanelFactory = shelfPanelFactory
        self.currentDisplayID = currentDisplayID
        self.uptime = uptime
        self.inputIdleTime = inputIdleTime
        self.idleTicks = idleTicks
        self.workspaceNotifications = workspaceNotifications
        self.applicationNotifications = applicationNotifications
        managementModel.supportsCollectedScope = false
        managementModel.selectsFirstResult = false
        shelfModel.supportsCollectedScope = false
        shelfModel.onActivate = { [weak self] id, inventory in self?.activateShelfItem(id, inventoryID: inventory) }
        self.arrangementModel.prepareToWrite = { [weak self] in
            guard let self, !self.isPreview, self.partitionMode == .systemVisibility else { return }
            self.cancelPresentation()
            self.driver?.revealAll()
            self.requestedPresentation = .all
            try await self.driver?.confirmRevealedLayout()
        }
    }

    func apply(_ settings: MenuBarSettings) {
        let previous = self.settings
        self.settings = settings
        guard !isPreview else { return }
        isActive = true
        observeEnvironment()
        shelfModel.supportsCollectedScope = partitionMode.supportsSections && settings.isEnabled
        if settings.isEnabled {
            if driver == nil {
                let driver = driverFactory()
                self.driver = driver
            }
            if !isEnabled || previous?.deepSectionEnabled != settings.deepSectionEnabled {
                let needsRecovery = environmentState != .ready
                cancelPresentation()
                cancelEnvironmentRecovery()
                driver?.install(deepSectionEnabled: partitionMode.supportsSections && settings.deepSectionEnabled)
                requestedPresentation = .all
                environmentState = isSleeping ? .sleeping : (needsRecovery ? .settling : .ready)
                message = nil
                if needsRecovery, !isSleeping { beginEnvironmentRecovery() }
            }
            driver?.setCollectedApplications(settings.collectedApplications)
            if let previous, previous.collectedApplications != settings.collectedApplications {
                if requestedPresentation != .all { revealAllPreservingRecovery() }
                if !arrangementModel.isApplying { arrangementModel.invalidate() }
                message = nil
            }
            isEnabled = true
        } else if isEnabled || driver != nil {
            disableCollection()
        }
        if previous?.autoCollapseEnabled != settings.autoCollapseEnabled || previous?.autoCollapseDelayMinutes != settings.autoCollapseDelayMinutes || previous?.collectedApplications != settings.collectedApplications {
            // 配置提交后取消旧的自动请求；手动收起不受这个开关影响。
            if autoCollapseRequestID == requestID {
                cancelPresentation()
                revealAllPreservingRecovery()
            }
            resetAutoCollapse()
        }
        // 只比较实际注册集合：收纳与搜索独立，不因无关配置重建快捷键或关闭搜索面板。
        if previous?.activeShortcuts != settings.activeShortcuts { applyHotKeys() }
    }

    func toggleCollection() {
        let current = pendingPresentation ?? requestedPresentation
        present(current == .collapsed ? (partitionMode.supportsSections ? .expanded : .all) : .collapsed)
    }

    func present(_ state: MenuBarPresentation) {
        guard !isPreview, isEnabled, let driver else { return }
        if state == .collapsed, needsCollectionSelection {
            // 空名单不启动系统隐藏事务；显式点击直接进入选择入口，自动计时不会走到这里。
            message = L10n.string(.MenuBar.collectionEmpty)
            requestCollectionSetup?()
            return
        }
        guard state == .all || environmentState == .ready else { return }
        if arrangementModel.isApplying { arrangementModel.invalidate() }
        invalidateItemInteraction()
        lastActionReceipt = nil
        cancelPresentation()
        if state == .all {
            message = nil
            revealAllPreservingRecovery()
            return
        }
        let request = requestID
        pendingPresentation = state
        presentationTask = Task { [weak self] in
            guard let self, self.requestID == request, self.isEnabled,
                  self.environmentState == .ready, !Task.isCancelled else { return }
            defer {
                if self.requestID == request {
                    self.pendingPresentation = nil; self.presentationTask = nil; self.autoCollapseRequestID = nil
                }
            }
            do {
                try await driver.present(state)
                guard self.requestID == request, !Task.isCancelled else { return }
                requestedPresentation = state
                message = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.requestID == request, !Task.isCancelled else { return }
                let detail = error.localizedDescription
                driver.revealAll()
                requestedPresentation = .all
                // 失败后保留展开与错误反馈，等待用户操作，不在空闲期间反复重试。
                autoCollapseObservation = nil
                message = detail
            }
        }
    }

    func finishPresentation() async { await presentationTask?.value }
    func finishEnvironmentRecovery() async { await environmentTask?.value }
    func finishItemRequest() async { await itemTask?.value }
    func recoverVisibilityAtLaunch() {
        guard !isPreview else { return }
        do { try MenuBarVisibilityRecovery().restore() }
        catch { message = error.localizedDescription; environmentState = .unconfirmed }
    }

    func refreshLanguage() { driver?.refreshLabels(); shelfModel.objectWillChange.send(); managementModel.objectWillChange.send() }

    private func resetAutoCollapse() {
        autoCollapseObservation = nil
        guard let settings, settings.autoCollapseEnabled, !isPreview, isActive, isEnabled, !isSleeping,
              !needsCollectionSelection, environmentState == .ready, requestedPresentation != .collapsed else { return }
        // 展开和环境恢复都从此刻重新等待，不能沿用展开前或休眠前的空闲时间。
        autoCollapseNotBefore = uptime() + settings.autoCollapseInterval
        autoCollapseObservation = idleTicks().sink { [weak self] in self?.collapseIfIdle() }
    }

    private func collapseIfIdle() {
        guard let settings, settings.autoCollapseEnabled, !isPreview, isActive, isEnabled, !isSleeping,
              !needsCollectionSelection, environmentState == .ready, requestedPresentation != .collapsed else { return }
        // 不抢占原生布局写入、图标取用或快捷键录制；操作结束后仍留出完整空闲期。
        guard pendingPresentation == nil, !arrangementModel.isApplying,
              itemTask == nil, !isActivatingItem, !isRecordingShortcut else {
            autoCollapseNotBefore = uptime() + settings.autoCollapseInterval
            return
        }
        guard uptime() >= autoCollapseNotBefore, inputIdleTime() >= settings.autoCollapseInterval else { return }
        autoCollapseObservation = nil
        present(.collapsed)
        autoCollapseRequestID = requestID
    }

    private func cancelPresentation() {
        requestID = UUID()
        autoCollapseRequestID = nil
        presentationTask?.cancel()
        presentationTask = nil
        pendingPresentation = nil
    }

    private func cancelEnvironmentRecovery() {
        environmentRequestID = UUID()
        environmentTask?.cancel()
        environmentTask = nil
    }

    /// 应用清单变化只撤销 AX 引用，不把已经收起的菜单栏擅自展开。
    /// 如果切换尚未结束，新图标可能改变正在验证的布局，此时仅取消这次切换并释放占位。
    func applicationsDidChange() {
        guard !isPreview, isActive else { return }
        arrangementModel.invalidate()
        invalidateItemInteraction()
        lastActionReceipt = nil
        if pendingPresentation != nil {
            cancelPresentation()
            driver?.revealAll()
            requestedPresentation = .all
            message = L10n.string(.MenuBar.runtimeApplicationChangeCancelled)
        }
    }

    /// 真正的屏幕／Space／睡眠变化采用保护性展开，不把它混同于普通应用启停。
    func environmentDidChange(_ change: MenuBarEnvironmentChange) {
        guard !isPreview, isActive else { return }
        arrangementModel.invalidate()
        if change == .sleep { isSleeping = true }
        if change == .wake { isSleeping = false }
        cancelPresentation()
        invalidateItemInteraction()
        cancelEnvironmentRecovery()
        lastActionReceipt = nil
        message = isEnabled && !isSleeping ? L10n.string(.MenuBar.runtimeLayoutRevealed) : nil
        environmentState = isSleeping ? .sleeping : (driver == nil ? .ready : .settling)
        revealAllPreservingRecovery()
    }

    private func revealAllPreservingRecovery() {
        driver?.revealAll()
        requestedPresentation = .all
        // 显示全部和全图标取用不依赖分区凭据；重复恢复仅更新确认代次，不关闭这两个入口。
        if let failure = driver?.recoveryFailure { environmentState = .unconfirmed; message = failure.localizedDescription }
        if !isSleeping, environmentState != .ready { beginEnvironmentRecovery() }
    }

    private func beginEnvironmentRecovery() {
        guard let driver else { return }
        cancelEnvironmentRecovery()
        environmentState = .settling
        let request = environmentRequestID
        environmentTask = Task { [weak self] in
            guard let self, self.environmentRequestID == request, self.isEnabled, !Task.isCancelled else { return }
            do {
                try await driver.confirmRevealedLayout()
                guard self.environmentRequestID == request, !Task.isCancelled else { return }
                self.environmentState = .ready
            } catch is CancellationError { return }
            catch {
                guard self.environmentRequestID == request, !Task.isCancelled else { return }
                self.environmentState = .unconfirmed
                self.message = error.localizedDescription
            }
        }
    }

    func stop() {
        isActive = false
        disableCollection()
        hotKeys?.stop(); hotKeys = nil; hotKeyFailures = [:]
        registeredHotKeyActions = []
        shortcutRecorders.removeAll(); isRecordingShortcut = false
        observations.removeAll()
        isSleeping = false
        environmentState = .ready
        settings = nil
    }

    private func disableCollection() {
        arrangementModel.invalidate()
        invalidateItemInteraction()
        cancelPresentation()
        cancelEnvironmentRecovery()
        driver?.remove()
        let recoveryFailure = driver?.recoveryFailure
        driver = nil
        isEnabled = false
        shelfModel.supportsCollectedScope = false
        requestedPresentation = .all
        environmentState = isSleeping ? .sleeping : (recoveryFailure == nil ? .ready : .unconfirmed)
        message = recoveryFailure?.localizedDescription
        lastActionReceipt = nil
    }

    func openAccessibilitySettings() {
        guard !isPreview else { return }
        SystemPrivacySettings.open(.accessibility)
    }

    func retryHotKeys() { guard !isPreview, isActive else { return }; applyHotKeys() }

    /// 录制时撤销本功能的全局拦截，避免按下已有组合却唤出菜单；旧控件不能恢复新控件的热键。
    func setShortcutRecording(owner: UUID, active: Bool) {
        guard !isPreview else { return }
        if active { shortcutRecorders.insert(owner) }
        else { guard shortcutRecorders.remove(owner) != nil else { return } }
        let recording = !shortcutRecorders.isEmpty
        guard isRecordingShortcut != recording else { return }
        isRecordingShortcut = recording
        if recording { hotKeys?.stop(); registeredHotKeyActions = [] }
        else if isActive { applyHotKeys() }
    }

    private func applyHotKeys() {
        guard let settings else { return }
        guard !isRecordingShortcut else { return }
        let shortcuts = settings.activeShortcuts
        guard !shortcuts.isEmpty else {
            hotKeys?.stop(); hotKeys = nil; hotKeyFailures = [:]; registeredHotKeyActions = []; return
        }
        if hotKeys == nil { hotKeys = hotKeyFactory() }
        hotKeyFailures = hotKeys?.apply(shortcuts) { [weak self] action in
            guard let self, self.isActive, !self.isSleeping, !self.isRecordingShortcut,
                  self.settings?.activeShortcuts[action] != nil else { return }
            switch action {
            case .shelf: self.toggleShelf(scope: .all)
            case .toggle: self.toggleCollection()
            case .reveal: self.present(.all)
            }
        } ?? [:]
        registeredHotKeyActions = Set(shortcuts.keys).subtracting(hotKeyFailures.keys)
    }

    /// 管理页与快捷面板共享一条取用链路；owner 让旧页面的退出和迟到回包不能接管新会话。
    func beginManagement(owner: UUID) {
        guard managementOwner != owner else { return }
        managementOwner = owner
        guard !isPreview else { return }
        refreshManagement(owner: owner, clearQuery: true)
    }

    func applyArrangement() {
        guard isPreview || (isEnabled && environmentState == .ready && pendingPresentation == nil) else { return }
        arrangementModel.apply()
    }

    func refreshManagement(owner: UUID, clearQuery: Bool = false) {
        guard managementOwner == owner, canSearchAllIcons, !isActivatingItem else { return }
        observeEnvironment()
        invalidateItemInteraction()
        let identity = ItemOwner.management(owner)
        itemOwner = identity
        managementModel.scope = .all
        refreshItems(owner: identity, model: managementModel, clearQuery: clearQuery)
    }

    func endManagement(owner: UUID) {
        guard managementOwner == owner else { return }
        managementOwner = nil
        if itemOwner == .management(owner) { invalidateItemInteraction() }
        if !isPreview { managementModel.clear() }
    }

    func activateManagementItem(_ id: UUID?, owner: UUID) {
        guard managementOwner == owner, itemOwner == .management(owner),
              let id = id ?? managementModel.selectedID, let inventory = managementModel.inventoryID else { return }
        activateItem(id, inventoryID: inventory, owner: .management(owner), model: managementModel)
    }

    func toggleShelf(scope: MenuBarShelfScope) {
        guard canSearchAllIcons else { return }
        guard scope == .all || isEnabled else { return }
        observeEnvironment()
        guard scope != .collected || partitionMode.supportsSections else {
            message = L10n.string(.MenuBar.overflowSectionsUnavailable)
            return
        }
        guard scope == .all || (isEnabled && environmentState == .ready) else { return }
        if shelfPanel?.isVisible == true {
            if shelfModel.scope == scope { closeShelf() }
            else { shelfModel.scope = scope }
            return
        }
        invalidateItemInteraction()
        lastActionReceipt = nil
        let owner = ItemOwner.shelf(UUID())
        itemOwner = owner
        shelfModel.scope = scope
        shelfModel.begin(clearQuery: true)
        shelfModel.feedback = message
        let panel = shelfPanelFactory(shelfModel, .init(refresh: { [weak self] in self?.refreshShelf(owner: owner) },
            openPermission: { [weak self] in self?.openAccessibilitySettings() },
            showAll: { [weak self] in self?.present(.all) }))
        panel.onDismiss = { [weak self] in
            guard self?.itemOwner == owner else { return }
            self?.closeShelf()
        }
        shelfPanel = panel
        do {
            panelDisplayID = try panel.show()
            refreshShelf(owner: owner)
        } catch { message = error.localizedDescription; closeShelf() }
    }

    func closeShelf() {
        guard itemOwner?.isShelf == true else { return }
        invalidateItemInteraction()
    }

    private func invalidateItemInteraction() {
        if case .management = itemOwner {
            managementModel.invalidate(L10n.string(.MenuBar.managementStale))
        }
        itemOwner = nil
        itemRequestID = UUID()
        itemTask?.cancel(); itemTask = nil
        shelfPanel?.close(); shelfPanel = nil
        itemAccess?.invalidate(); itemAccess = nil
        shelfModel.clear()
        panelDisplayID = nil
        isActivatingItem = false
    }

    private func refreshShelf(owner: ItemOwner) {
        guard itemOwner == owner, canSearchAllIcons, shelfPanel?.isVisible == true, !isActivatingItem else { return }
        guard shelfModel.scope == .all || isEnabled else { return }
        refreshItems(owner: owner, model: shelfModel, clearQuery: false)
    }

    private func refreshItems(owner: ItemOwner, model: MenuBarShelfModel, clearQuery: Bool) {
        itemTask?.cancel()
        itemRequestID = UUID()
        let request = itemRequestID
        model.begin(clearQuery: clearQuery)
        itemAccess?.invalidate(); itemAccess = nil
        itemTask = Task { [weak self] in
            guard let self, self.itemRequestID == request, self.itemOwner == owner,
                  self.isActive, !self.isSleeping, !Task.isCancelled else { return }
            let access = accessSessionFactory()
            var adopted = false
            defer {
                if !adopted { access.invalidate() }
                if self.itemRequestID == request { self.itemTask = nil }
            }
            do {
                let before = try? driver?.layoutSnapshot()
                let result = try await captureInventory(access)
                guard self.itemRequestID == request, self.itemOwner == owner, !Task.isCancelled else { return }
                itemAccess = access; adopted = true
                let after = try? driver?.layoutSnapshot()
                let partition = MenuBarPartitionSnapshot.validated(before: before, after: after, inventory: result, targetDisplayID: panelDisplayID)
                model.load(result, partition: partition, targetDisplayID: panelDisplayID)
            } catch is CancellationError { return }
            catch {
                guard self.itemRequestID == request, self.itemOwner == owner else { return }
                model.fail(error.localizedDescription, permissionRequired: (error as? MenuBarItemAccessError)?.requiresPermission == true)
            }
        }
    }

    private func activateShelfItem(_ id: UUID, inventoryID: UUID) {
        guard let owner = itemOwner, owner.isShelf else { return }
        activateItem(id, inventoryID: inventoryID, owner: owner, model: shelfModel)
    }

    private func activateItem(_ id: UUID, inventoryID: UUID, owner: ItemOwner, model: MenuBarShelfModel) {
        guard !isPreview, isActive, !isSleeping, !isActivatingItem, itemOwner == owner,
              model.inventoryID == inventoryID, let access = itemAccess,
              model.filteredItems.contains(where: { $0.id == id && model.canActivate($0) }) else { return }
        guard let displayID = owner.isShelf ? panelDisplayID : currentDisplayID() else {
            model.invalidate(L10n.string(.MenuBar.accessDisplayChanged)); return
        }
        let scope = model.scope
        guard scope == .all || (isEnabled && environmentState == .ready) else { return }
        let observedPartition = model.partition
        isActivatingItem = true
        model.beginActivation(id)
        if owner.isShelf { shelfPanel?.close() }
        itemTask?.cancel()
        itemRequestID = UUID()
        let request = itemRequestID
        let interruptedTransition = pendingPresentation != nil
        cancelPresentation()
        if interruptedTransition {
            // 点按不能与未完成的布局写入并发；仅中断正在进行的切换，不展开一个稳定收起的区域。
            driver?.revealAll()
            requestedPresentation = .all
        }
        itemTask = Task { [weak self] in
            guard let self, self.itemRequestID == request, self.itemOwner == owner,
                  self.isActive, !self.isSleeping, !Task.isCancelled else { return }
            defer {
                if self.itemRequestID == request {
                    self.isActivatingItem = false; self.itemTask = nil
                    model.endActivation()
                }
            }
            do {
                let constraint: MenuBarCollectionConstraint?
                if scope == .collected {
                    guard isEnabled, let driver, let observedPartition, try driver.layoutSnapshot() == observedPartition else { throw MenuBarItemAccessError.sectionChanged }
                    try await driver.present(.expanded)
                    requestedPresentation = .expanded
                    let active = try driver.layoutSnapshot()
                    constraint = .init(snapshot: active, isCurrent: { (try? driver.layoutSnapshot()) == active })
                } else {
                    // 全图标直接作用于已验证的 AX 对象，不通过“全部展开”来冒充单项取用。
                    constraint = nil
                }
                try Task.checkCancellation()
                guard self.itemRequestID == request, self.itemOwner == owner, isActive, !isSleeping else { return }
                try access.activate(itemID: id, inventoryID: inventoryID, displayID: displayID, collection: constraint)
                lastActionReceipt = L10n.string(.MenuBar.accessAccepted)
                if owner.isShelf {
                    message = nil
                    itemAccess?.invalidate(); itemAccess = nil
                    model.clear()
                } else {
                    // 只消费本行令牌；其他图标仍可取用，已发送行必须刷新后才能再次点按。
                    model.finishActivation(id, outcome: .sent)
                }
            } catch is CancellationError { return }
            catch {
                guard self.itemRequestID == request, self.itemOwner == owner else { return }
                itemAccess?.invalidate(); itemAccess = nil
                let detail = error.localizedDescription
                let permissionRequired = (error as? MenuBarItemAccessError)?.requiresPermission == true
                let unconfirmed: Bool
                if case MenuBarItemAccessError.requestUnconfirmed = error { unconfirmed = true }
                else { unconfirmed = false }
                if owner.isShelf {
                    message = detail
                    model.fail(detail, permissionRequired: permissionRequired)
                    // 超时不重开面板抢走原生菜单焦点，也不重放动作。
                    if !unconfirmed {
                        do { panelDisplayID = try shelfPanel?.show() }
                        catch { message = error.localizedDescription; closeShelf() }
                    }
                } else if permissionRequired {
                    model.fail(detail, permissionRequired: true)
                } else {
                    model.finishActivation(id, outcome: unconfirmed ? .unconfirmed(detail) : .failed(detail))
                    model.invalidate(L10n.string(.MenuBar.managementStale))
                }
            }
        }
    }

    private func observeEnvironment() {
        guard observations.isEmpty else { return }
        // 睡眠期间的迟到切屏通知不能解除暂停；只有真实唤醒通知才开始稳定确认。
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceNotifications.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.applicationsDidChange()
            }.store(in: &observations)
        }
        for (name, change) in [(NSWorkspace.activeSpaceDidChangeNotification, MenuBarEnvironmentChange.layout),
                               (NSWorkspace.didWakeNotification, .wake), (NSWorkspace.willSleepNotification, .sleep)] {
            workspaceNotifications.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.environmentDidChange(change)
            }.store(in: &observations)
        }
        applicationNotifications.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.environmentDidChange(.layout) }.store(in: &observations)
    }
}
