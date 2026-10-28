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
    @Published private(set) var isEnabled = false
    @Published private(set) var requestedPresentation: MenuBarPresentation = .all
    @Published private(set) var message: String?
    @Published private(set) var lastActionReceipt: String?
    @Published private(set) var inventory: MenuBarInventory?
    @Published private(set) var inventoryPartition: MenuBarPartitionSnapshot?
    @Published private(set) var isInspecting = false
    @Published private(set) var environmentState: MenuBarEnvironmentState = .ready
    let shelfModel = MenuBarShelfModel()
    @Published private(set) var hotKeyFailures: [MenuBarHotKeyAction: Int32] = [:]
    let isPreview: Bool
    let partitionMode: MenuBarPartitionMode
    private let driverFactory: () -> any MenuBarPartitionDriving
    private var driver: (any MenuBarPartitionDriving)?
    private var settings: MenuBarSettings?
    private var observations: [AnyCancellable] = []
    private var inspection: Task<Void, Never>?
    private var inspectionRequestID = UUID()
    private var presentationTask: Task<Void, Never>?
    private var requestID = UUID()
    private var environmentTask: Task<Void, Never>?
    private var environmentRequestID = UUID()
    private var isSleeping = false
    private let captureInventory: () async throws -> MenuBarInventory
    private let workspaceNotifications: NotificationCenter
    private let applicationNotifications: NotificationCenter
    private let hotKeyFactory: () -> any MenuBarHotKeyDriving
    private var hotKeys: (any MenuBarHotKeyDriving)?
    private let itemAccess = MenuBarItemAccessSession()
    private var shelfPanel: MenuBarShelfPanel?
    private var shelfTask: Task<Void, Never>?
    private var shelfRequestID = UUID()
    private var shelfDisplayID: UInt32?
    private var isActivatingItem = false

    init(isPreview: Bool = false, partitionMode: MenuBarPartitionMode = .current,
         driverFactory: (() -> any MenuBarPartitionDriving)? = nil,
         hotKeyFactory: @escaping () -> any MenuBarHotKeyDriving = { NativeMenuBarHotKeys() },
         captureInventory: @escaping () async throws -> MenuBarInventory = { try await MenuBarInspector().captureForInteraction() },
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         applicationNotifications: NotificationCenter = .default) {
        self.isPreview = isPreview
        self.partitionMode = partitionMode
        self.driverFactory = driverFactory ?? { NativeMenuBarPartitions(mode: partitionMode) }
        self.hotKeyFactory = hotKeyFactory
        self.captureInventory = captureInventory
        self.workspaceNotifications = workspaceNotifications
        self.applicationNotifications = applicationNotifications
        shelfModel.supportsCollectedScope = partitionMode.supportsSections
        shelfModel.onActivate = { [weak self] id, inventory in self?.activateShelfItem(id, inventoryID: inventory) }
    }

    func apply(_ settings: MenuBarSettings) {
        let previous = self.settings
        let wasEnabled = isEnabled
        self.settings = settings
        guard !isPreview else { return }
        guard settings.isEnabled else {
            // 已经停用时，其他设置提交不能取消用户单独发起的只读清单查询。
            if wasEnabled || driver != nil || hotKeys != nil { stop() }
            return
        }
        if driver == nil {
            let driver = driverFactory()
            driver.onRequest = { [weak self] in self?.present($0) }
            driver.onOpenShelf = { [weak self] in self?.toggleShelf(scope: $0) }
            self.driver = driver
            observeEnvironment()
        }
        if !isEnabled || previous?.deepSectionEnabled != settings.deepSectionEnabled {
            let needsRecovery = environmentState != .ready
            cancelPresentation()
            cancelEnvironmentRecovery()
            driver?.install(deepSectionEnabled: partitionMode.supportsSections && settings.deepSectionEnabled)
            requestedPresentation = .all
            // 配置重装不能绕过尚未稳定的环境；重新确认新的控件，旧回读仍按代次拒绝。
            environmentState = isSleeping ? .sleeping : (needsRecovery ? .settling : .ready)
            message = nil
            if needsRecovery, !isSleeping { beginEnvironmentRecovery() }
        }
        isEnabled = true
        if !wasEnabled || previous?.shelfShortcut != settings.shelfShortcut || previous?.revealShortcut != settings.revealShortcut {
            applyHotKeys()
        }
    }

    func present(_ state: MenuBarPresentation) {
        guard !isPreview, isEnabled, let driver else { return }
        guard state == .all || environmentState == .ready else { return }
        closeShelf()
        lastActionReceipt = nil
        cancelPresentation()
        if state == .all {
            message = nil
            revealAllPreservingRecovery()
            return
        }
        let request = requestID
        presentationTask = Task { [weak self] in
            guard let self, self.requestID == request, self.isEnabled,
                  self.environmentState == .ready, !Task.isCancelled else { return }
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
                message = detail
            }
        }
    }

    func finishPresentation() async { await presentationTask?.value }
    func finishEnvironmentRecovery() async { await environmentTask?.value }
    func refreshLanguage() { driver?.refreshLabels(); shelfModel.objectWillChange.send() }

    private func cancelPresentation() {
        requestID = UUID()
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func cancelEnvironmentRecovery() {
        environmentRequestID = UUID()
        environmentTask?.cancel()
        environmentTask = nil
    }

    private func invalidateInventory() {
        inspectionRequestID = UUID()
        inspection?.cancel(); inspection = nil
        isInspecting = false
        inventory = nil
        inventoryPartition = nil
    }

    /// 环境变化撤销全部旧观察和动作；恢复只回到显示全部，不自动重放收起或图标取用。
    func environmentDidChange(_ change: MenuBarEnvironmentChange) {
        guard !isPreview, isEnabled else { return }
        if change == .sleep { isSleeping = true }
        if change == .wake { isSleeping = false }
        cancelPresentation()
        closeShelf()
        invalidateInventory()
        cancelEnvironmentRecovery()
        lastActionReceipt = nil
        message = nil
        environmentState = isSleeping ? .sleeping : .settling
        revealAllPreservingRecovery()
    }

    private func revealAllPreservingRecovery() {
        driver?.revealAll()
        requestedPresentation = .all
        // 显示全部和全图标取用不依赖分区凭据；重复恢复仅更新确认代次，不关闭这两个入口。
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
        closeShelf()
        hotKeys?.stop(); hotKeys = nil; hotKeyFailures = [:]
        cancelPresentation()
        cancelEnvironmentRecovery()
        invalidateInventory()
        driver?.remove(); driver = nil
        observations.removeAll()
        isEnabled = false
        requestedPresentation = .all
        environmentState = .ready
        isSleeping = false
        message = nil
        lastActionReceipt = nil
        settings = nil
    }

    func refreshInventory() {
        guard !isPreview, !isInspecting, !isSleeping else { return }
        isInspecting = true
        inspectionRequestID = UUID()
        let request = inspectionRequestID
        // 发现是显式只读操作；不要求先启用分区，也不会为了读取而更改图标可见性。
        inspection = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            defer { if inspectionRequestID == request { isInspecting = false } }
            do {
                let before = try? driver?.layoutSnapshot()
                let result = try await captureInventory()
                guard inspectionRequestID == request, !Task.isCancelled else { return }
                let after = try? driver?.layoutSnapshot()
                inventoryPartition = .validated(before: before, after: after, inventory: result, targetDisplayID: before?.displayID)
                inventory = result
            } catch is CancellationError { return }
            catch { if inspectionRequestID == request { message = error.localizedDescription } }
        }
    }

    func openAccessibilitySettings() {
        guard !isPreview else { return }
        SystemPrivacySettings.open(.accessibility)
    }

    func retryHotKeys() { guard !isPreview, isEnabled else { return }; applyHotKeys() }

    private func applyHotKeys() {
        guard let settings else { return }
        guard settings.shelfShortcut != .disabled || settings.revealShortcut != .disabled else {
            hotKeys?.stop(); hotKeys = nil; hotKeyFailures = [:]; return
        }
        if hotKeys == nil { hotKeys = hotKeyFactory() }
        hotKeyFailures = hotKeys?.apply(shelf: settings.shelfShortcut, reveal: settings.revealShortcut) { [weak self] action in
            switch action {
            case .shelf: self?.toggleShelf(scope: .all)
            case .reveal: self?.present(.all)
            }
        } ?? [:]
    }

    func toggleShelf(scope: MenuBarShelfScope) {
        guard !isPreview, isEnabled, !isSleeping else { return }
        guard scope != .collected || partitionMode.supportsSections else {
            message = L10n.string(.MenuBar.overflowSectionsUnavailable)
            return
        }
        guard scope == .all || environmentState == .ready else { return }
        if shelfPanel?.isVisible == true {
            if shelfModel.scope == scope { closeShelf() }
            else { shelfModel.scope = scope }
            return
        }
        closeShelf()
        lastActionReceipt = nil
        shelfModel.scope = scope
        shelfModel.begin(clearQuery: true)
        shelfModel.feedback = message
        let panel = MenuBarShelfPanel(model: shelfModel, refresh: { [weak self] in self?.refreshShelf() },
            openPermission: { [weak self] in self?.openAccessibilitySettings() },
            showAll: { [weak self] in self?.present(.all) })
        panel.onDismiss = { [weak self] in self?.closeShelf() }
        shelfPanel = panel
        do {
            shelfDisplayID = try panel.show()
            refreshShelf()
        } catch { message = error.localizedDescription; closeShelf() }
    }

    func closeShelf() {
        shelfRequestID = UUID()
        shelfTask?.cancel(); shelfTask = nil
        shelfPanel?.close(); shelfPanel = nil
        itemAccess.invalidate()
        shelfModel.clear()
        shelfDisplayID = nil
        isActivatingItem = false
    }

    private func refreshShelf() {
        guard !isPreview, isEnabled, shelfPanel?.isVisible == true, !isActivatingItem else { return }
        shelfTask?.cancel()
        shelfRequestID = UUID()
        let request = shelfRequestID
        shelfModel.begin(clearQuery: false)
        itemAccess.invalidate()
        shelfTask = Task { [weak self] in
            guard let self, self.shelfRequestID == request, self.isEnabled, !Task.isCancelled else { return }
            do {
                let before = try? driver?.layoutSnapshot()
                let result = try await MenuBarInspector().captureForInteraction(session: itemAccess)
                guard self.shelfRequestID == request, !Task.isCancelled else { return }
                let after = try? driver?.layoutSnapshot()
                let partition = MenuBarPartitionSnapshot.validated(before: before, after: after, inventory: result, targetDisplayID: shelfDisplayID)
                shelfModel.load(result, partition: partition, targetDisplayID: shelfDisplayID)
            } catch is CancellationError { return }
            catch {
                guard self.shelfRequestID == request else { return }
                shelfModel.fail(error.localizedDescription)
            }
        }
    }

    private func activateShelfItem(_ id: UUID, inventoryID: UUID) {
        guard !isPreview, isEnabled, !isActivatingItem, let displayID = shelfDisplayID,
              shelfModel.inventoryID == inventoryID, let driver else { return }
        let scope = shelfModel.scope
        guard scope == .all || environmentState == .ready else { return }
        let observedPartition = shelfModel.partition
        guard shelfModel.filteredItems.contains(where: { $0.id == id && $0.supportsActivation }) else { return }
        isActivatingItem = true
        shelfPanel?.close()
        shelfTask?.cancel()
        shelfRequestID = UUID()
        let request = shelfRequestID
        cancelPresentation()
        shelfTask = Task { [weak self] in
            guard let self, self.shelfRequestID == request, self.isEnabled, !Task.isCancelled else { return }
            do {
                let constraint: MenuBarCollectionConstraint?
                if scope == .collected {
                    guard let observedPartition, try driver.layoutSnapshot() == observedPartition else { throw MenuBarItemAccessError.sectionChanged }
                    // 普通收纳只展开普通区。失败时保持当前状态，不能静默暴露深度区。
                    requestedPresentation = .expanded
                    try await driver.present(.expanded)
                    let active = try driver.layoutSnapshot()
                    constraint = .init(snapshot: active, isCurrent: { (try? driver.layoutSnapshot()) == active })
                } else {
                    revealAllPreservingRecovery()
                    try await Task.sleep(for: .milliseconds(120))
                    constraint = nil
                }
                try Task.checkCancellation()
                guard self.shelfRequestID == request, isEnabled else { return }
                try itemAccess.activate(itemID: id, inventoryID: inventoryID, displayID: displayID, collection: constraint)
                message = nil
                lastActionReceipt = L10n.string(.MenuBar.accessAccepted)
                itemAccess.invalidate()
                shelfModel.clear()
            } catch is CancellationError { return }
            catch {
                guard self.shelfRequestID == request else { return }
                itemAccess.invalidate()
                message = error.localizedDescription
                shelfModel.fail(error.localizedDescription, permissionRequired: (error as? MenuBarItemAccessError)?.requiresPermission == true)
                // AX 超时可能已经执行，不能重新抢焦点或重试。发送前的拒绝可以在面板解释。
                if case MenuBarItemAccessError.requestUnconfirmed = error { }
                else {
                    do { shelfDisplayID = try shelfPanel?.show() }
                    catch { message = error.localizedDescription; closeShelf() }
                }
            }
            guard self.shelfRequestID == request else { return }
            isActivatingItem = false
        }
    }

    private func observeEnvironment() {
        // 睡眠期间的迟到切屏通知不能解除暂停；只有真实唤醒通知才开始稳定确认。
        for (name, change) in [(NSWorkspace.didLaunchApplicationNotification, MenuBarEnvironmentChange.layout),
                               (NSWorkspace.activeSpaceDidChangeNotification, .layout),
                               (NSWorkspace.didWakeNotification, .wake), (NSWorkspace.willSleepNotification, .sleep)] {
            workspaceNotifications.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.environmentDidChange(change)
            }.store(in: &observations)
        }
        applicationNotifications.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.environmentDidChange(.layout) }.store(in: &observations)
    }
}
