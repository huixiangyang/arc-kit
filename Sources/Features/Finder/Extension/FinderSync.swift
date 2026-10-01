import ArcKitFinder
import ArcKitPlatform
import AppKit
import FinderSync
import os.log

/// Finder 扩展入口。菜单由菜单树/渲染器构建，点击从注册表解析目标后交给动作协调器。
final class FinderSync: FIFinderSync, @unchecked Sendable {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.archalo.arckit.finder-extension", category: "FinderSync")
    private let snapshotStore: FinderExtensionSnapshotStore
    private var menuState: FinderMenuRuntimeState?
    private let menuIcons = FinderMenuIcons()
    private var snapshotObserver: NSObjectProtocol?
    private var runtimeStateRequestObserver: NSObjectProtocol?
    private var recentStateResponses: [FinderExtensionStateResponse] = []
    private var snapshotRefreshWorkItem: DispatchWorkItem?
    private var snapshotFetchInFlight = false
    private var pendingSnapshotReason: String?
    private var lastMenuBuildRuntime: FinderExtensionMenuBuildRuntime?
    private var lastActionRuntime: FinderExtensionActionRuntime?
    private var lastActionSelectionID: UUID?
    private let toolbarIcon: NSImage = {
        let image = ArcIconImage.image(.wrench)
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    // 云盘可能不向第三方扩展提供右键回调；工具栏是 Finder Sync 的独立公开入口。
    override var toolbarItemName: String { "Arc Kit" }
    override var toolbarItemToolTip: String { L10n.string(.FinderExtension.extensionArcKitFileActions) }
    override var toolbarItemImage: NSImage { toolbarIcon }

    override init() {
        ArcKitSubprocessEnvironment.scrubSensitiveVariablesFromCurrentProcess()
        let startedAt = Date()
        ArcKitLog.append("extension init begin")
        let snapshotStore = FinderExtensionSnapshotStore()
        self.snapshotStore = snapshotStore
        super.init()
        configureDefaultObservedDirectories()
        observeSnapshotChanges()
        observeRuntimeStateRequests()
        requestLatestSnapshot(reason: "extension-init")
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        ArcKitLog.append("extension init ready durationMs=\(durationMs)")
        reportRuntimeState(event: .initialized)
    }

    deinit {
        snapshotRefreshWorkItem?.cancel()
        if let snapshotObserver {
            DistributedNotificationCenter.default().removeObserver(snapshotObserver)
        }
        if let runtimeStateRequestObserver {
            DistributedNotificationCenter.default().removeObserver(runtimeStateRequestObserver)
        }
    }

    /// Finder Sync 的菜单触发依赖 directoryURLs；初始化时先写入默认目录，避免等待 snapshot IO 才能出菜单。
    private func configureDefaultObservedDirectories() {
        let paths = FinderObservedDirectoryBuilder.defaultObservedDirectoryPaths(
            validationMode: .extensionRuntime
        )
        let urls = FinderObservedDirectoryBuilder.urls(from: paths)
        FIFinderSyncController.default().directoryURLs = urls
        ArcKitLog.append("extension directoryURLs default count=\(urls.count)")
    }

    private func observeSnapshotChanges() {
        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ArcKitConstants.finderSnapshotChangedDistributedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 分布式通知只负责唤醒，不再携带可伪造的菜单配置。
            self.menuState = nil
            self.snapshotRequestGeneration += 1
            self.scheduleLatestSnapshotRequest(reason: "snapshot-changed")
        }
    }

    /// changed 通知可由同用户进程发送，因此必须去抖；连续噪声只保留最后一次
    /// 安全 XPC 拉取，不能放大成无界目录枚举。
    private func scheduleLatestSnapshotRequest(reason: String) {
        snapshotRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.requestLatestSnapshot(reason: reason)
        }
        snapshotRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private var snapshotRequestGeneration = 0
    private var lastSnapshotRequestAt = Date.distantPast

    private func requestLatestSnapshot(reason: String) {
        guard !snapshotFetchInFlight else {
            pendingSnapshotReason = reason
            return
        }
        snapshotFetchInFlight = true
        lastSnapshotRequestAt = Date()
        let generation = snapshotRequestGeneration
        FinderAgentSecureIPCClient.shared.fetchSnapshot { [weak self] result in
            guard let self else { return }
            self.snapshotFetchInFlight = false
            guard generation == self.snapshotRequestGeneration else {
                self.scheduleLatestSnapshotRequest(reason: "superseded")
                return
            }
            switch result {
            case let .success(reply):
                guard let snapshot = reply.snapshot else {
                    ArcKitLog.append("extension secure snapshot missing reason=\(reason)")
                    return
                }
                L10n.configure(snapshot.language)
                self.snapshotStore.receive(snapshot, reason: "extension-secure-\(reason)")
                self.menuState = FinderMenuRuntimeState(snapshot: snapshot)
                if let state = self.menuState { self.menuIcons.prepare(for: state.treeState) }
                self.applyObservedDirectories(snapshot: snapshot, reason: "secure-\(reason)")
            case let .failure(error):
                self.menuState = nil
                ArcKitLog.append(
                    "extension secure snapshot failed reason=\(reason) error=\(error.localizedDescription)"
                )
            }
            if let pendingReason = self.pendingSnapshotReason {
                self.pendingSnapshotReason = nil
                self.scheduleLatestSnapshotRequest(reason: pendingReason)
            }
        }
    }

    private func observeRuntimeStateRequests() {
        runtimeStateRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ArcKitConstants.finderExtensionRuntimeStateRequestDistributedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawID = notification.userInfo?["requestID"] as? String,
                  let requestID = UUID(uuidString: rawID) else { return }
            // 通知只携带关联编号；状态仍通过身份校验后的 Mach service 上报。
            let now = Date()
            self.recentStateResponses.removeAll {
                $0.requestID == requestID || now.timeIntervalSince($0.respondedAt) > 30
            }
            self.recentStateResponses.append(.init(requestID: requestID, respondedAt: now))
            self.recentStateResponses = Array(self.recentStateResponses.suffix(8))
            ArcKitLog.append("extension runtime state requested requestID=\(requestID)")
            self.reportRuntimeState(event: .stateRequestResponse)
        }
    }

    private func applyObservedDirectories(snapshot: FinderExtensionSnapshot, reason: String) {
        let urls = FinderObservedDirectoryBuilder.urls(from: snapshot.observedDirectoryPaths)
        FIFinderSyncController.default().directoryURLs = urls
        ArcKitLog.append(
            "extension directoryURLs refreshed reason=\(reason) count=\(urls.count) snapshot version=\(snapshot.schemaVersion)"
        )
        reportRuntimeState(event: .observedDirectoriesUpdated)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let startedAt = Date()
        guard menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForItems
            || menuKind == .contextualMenuForSidebar || menuKind == .toolbarItemMenu else { return nil }
        // 先排除虚拟 URL 再提取 path，避免把云盘虚拟标识重新解释成本地文件路径。
        let selectedURLs = FinderContextCollector.selectedURLs.filter(\.isFileURL)
        let targetURL = FinderContextCollector.targetedURL.flatMap { $0.isFileURL ? $0 : nil }
        // 所有回调都留痕，区分系统未调用、快照未就绪和菜单被配置过滤；不再只记录慢菜单。
        ArcKitLog.append(
            "finder menu requested kind=\(menuKind.rawValue) prepared=\(menuState != nil) " +
            "selectedCount=\(selectedURLs.count) hasTarget=\(targetURL != nil)"
        )
        guard let state = menuState else {
            if Date().timeIntervalSince(lastSnapshotRequestAt) > 5 { scheduleLatestSnapshotRequest(reason: "menu-unavailable") }
            ArcKitLog.append("finder menu unavailable reason=snapshot-unavailable")
            return menuKind == .toolbarItemMenu ? toolbarNotice(L10n.string(.FinderExtension.extensionMenuNotReadyRetryLater)) : nil
        }
        let context = FinderMenuBuildContext(menuKind: menuKind, selectedURLs: selectedURLs, targetedURL: targetURL)
        let actionTarget = FinderContextCollector.makeActionTarget(
            selectedPaths: selectedURLs.map(\.path),
            targetedPath: targetURL?.path,
            menuKind: menuKind,
            targetKind: context.targetContext.kind
        )
        var menu = FinderMenuRenderer.buildMenu(state: state, icons: menuIcons, context: context, actionTarget: actionTarget)
        if menuKind == .toolbarItemMenu {
            if !state.isEnabled {
                menu = toolbarNotice(L10n.string(.FinderExtension.extensionFinderOff))
            } else if !context.hasAnyTarget {
                // 未提供目标时仍可打开常用目录，但不能伪造当前路径来执行文件操作。
                let result = toolbarNotice(L10n.string(.FinderExtension.extensionFinderProvidedTargetSelectFileMissing))
                if let actions = menu, !actions.items.isEmpty {
                    result.addItem(.separator())
                    for item in actions.items { actions.removeItem(item); result.addItem(item) }
                }
                menu = result
            } else if menu == nil {
                menu = toolbarNotice(L10n.string(.FinderExtension.extensionApplicableMenuItemsCheckArcKitMissing))
            }
        }
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        lastMenuBuildRuntime = FinderExtensionMenuBuildRuntime(
            menuKindRawValue: menuKind.rawValue,
            itemCount: menu?.items.count ?? 0,
            durationMs: durationMs,
            targetKind: context.targetContext.kind,
            selectedItemCount: context.targetContext.selectedItemCount,
            targetedPath: targetURL?.path,
            imageCount: menu.map(menuImageCount) ?? 0
        )
        reportRuntimeState(event: .menuBuilt)
        ArcKitLog.append(
            "finder menu built kind=\(menuKind.rawValue) durationMs=\(durationMs) " +
            "prepared=true snapshot version=\(state.snapshotVersion) itemCount=\(menu?.items.count ?? 0)"
        )
        return menu
    }

    override func beginObservingDirectory(at url: URL) {
        ArcKitLog.append("finder observation began path=\(url.path)")
    }

    override func endObservingDirectory(at url: URL) {
        ArcKitLog.append("finder observation ended path=\(url.path)")
    }

    private func toolbarNotice(_ title: String) -> NSMenu {
        let menu = NSMenu(title: "Arc Kit")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return menu
    }

    private func reportRuntimeState(event: FinderExtensionRuntimeEvent) {
        let state = menuState
        let runtimeState = FinderExtensionRuntimeState(
            processID: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? "",
            event: event,
            recentStateResponses: recentStateResponses,
            snapshotVersion: state?.snapshotVersion ?? FinderExtensionSnapshot.currentSchemaVersion,
            isMenuCachePrepared: state != nil,
            observedDirectoryPaths: FIFinderSyncController.default().directoryURLs
                .map(\.standardizedFileURL.path)
                .sorted(),
            lastMenuBuild: lastMenuBuildRuntime,
            lastAction: lastActionRuntime
        )
        FinderAgentSecureIPCClient.shared.reportRuntimeState(runtimeState) { result in
            if case let .failure(error) = result {
                ArcKitLog.append(
                    "extension secure runtime state failed event=\(event.rawValue) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func menuImageCount(_ menu: NSMenu) -> Int {
        menu.items.reduce(into: 0) { count, item in
            if item.image != nil { count += 1 }
            if let submenu = item.submenu { count += menuImageCount(submenu) }
        }
    }

    /// Finder Sync 在真实 Finder 进程里可能忽略 `NSMenuItem.target`，只把 action 发给
    /// `FIFinderSync` 主对象。这里是当前唯一主回调入口，避免恢复一堆旧 selector。
    @objc func performMenuAction(_ sender: NSMenuItem) {
        let tag = sender.tag
        let selectionID = UUID()
        lastActionSelectionID = selectionID
        ArcKitLog.append("finder sync action selected tag=\(tag) title=\(sender.title)")
        let resolvedAction = FinderMenuActionRegistry.registration(forTag: tag)
        if let resolvedAction {
            let executionMode = resolvedAction.descriptor.commandKind == .extensionLocalInfo ? FinderActionExecutionMode.extensionLocal : .agent
            lastActionRuntime = FinderExtensionActionRuntime(
                actionID: resolvedAction.descriptor.actionID,
                menuItemTag: tag,
                title: resolvedAction.descriptor.title,
                commandKind: resolvedAction.descriptor.commandKind,
                targetKind: resolvedAction.target.targetKind,
                selectedItemCount: resolvedAction.target.sourcePaths.count,
                targetPath: resolvedAction.target.sourcePaths.first
                    ?? resolvedAction.target.targetPath
                    ?? resolvedAction.target.currentDirectoryPath,
                needsHostTargetResolution: resolvedAction.target.needsHostTargetResolution,
                wasResolved: true,
                executionMode: executionMode
            )
        } else {
            lastActionRuntime = FinderExtensionActionRuntime(
                actionID: "unregistered:\(tag)",
                menuItemTag: tag,
                title: sender.title,
                commandKind: .extensionLocalInfo,
                targetKind: lastMenuBuildRuntime?.targetKind ?? .blank,
                selectedItemCount: lastMenuBuildRuntime?.selectedItemCount ?? 0,
                targetPath: lastMenuBuildRuntime?.targetedPath,
                needsHostTargetResolution: lastMenuBuildRuntime?.targetedPath == nil,
                wasResolved: false,
                executionMode: .agent,
                dispatchStatus: .rejected,
                failureReason: L10n.string(.FinderExtension.extensionMenuRegistrationExpiredTag(String(describing: tag)))
            )
        }
        reportRuntimeState(event: .actionSelected)
        Task { @MainActor in
            let outcome = FinderActionCoordinator.dispatch(resolvedAction, menuItemTag: tag)
            // 输入面板可运行嵌套事件循环，早先动作完成不能覆盖后续点击的诊断。
            guard self.lastActionSelectionID == selectionID else { return }
            self.applyDispatchOutcome(outcome)
        }
    }

    @MainActor
    private func applyDispatchOutcome(_ outcome: FinderActionDispatchOutcome) {
        guard var action = lastActionRuntime else { return }
        switch outcome {
        case .extensionCompleted:
            action.dispatchStatus = .extensionCompleted
            action.requestID = nil
            action.failureReason = nil
        case let .commandQueued(requestID):
            action.dispatchStatus = .commandQueued
            action.requestID = requestID
            action.failureReason = nil
        case let .cancelled(reason):
            action.dispatchStatus = .cancelled
            action.requestID = nil
            action.failureReason = reason
        case let .rejected(reason):
            action.dispatchStatus = .rejected
            action.requestID = nil
            action.failureReason = reason
        }
        lastActionRuntime = action
        reportRuntimeState(event: .actionDispatched)
    }
}
