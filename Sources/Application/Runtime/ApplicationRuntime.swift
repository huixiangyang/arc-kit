import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import Combine
import Foundation

/// 后台服务的应用级组合根。这里拥有运行会话；菜单和编辑器没有可写的运行态副本。
@MainActor
final class ApplicationRuntime {
    let permissions = ApplicationPermissions(isPreview: false)
    let host: RuntimeHostCoordinator
    let mouseService: MouseScrollEnhancementService
    let windowService: WindowManagementService
    let hotKeyService: GlobalHotKeyService
    let dragSnapService: WindowDragSnapService
    let snapshotStore = FinderExtensionSnapshotStore()
    var stateDidChange: (() -> Void)?
    var settingsDidCommit: ((AppSettings?, AppSettings) -> Void)?
    var committedSettings: AppSettings? { settingsSession.current }

    private let settingsModel: SettingsModel
    private var serviceCancellables: Set<AnyCancellable> = []
    private var isStarted = false
    private lazy var settingsSession: RuntimeSettingsSession = RuntimeSettingsSession(
        model: settingsModel,
        didCommit: { [weak self] previous, current in
            guard let self else { return }
            L10n.configure(current.language)
            host.apply(current, revision: settingsModel.committedRevision?.runtime ?? 0)
            if previous?.finder != current.finder || previous?.language != current.language { snapshotStore.publish(settings: current.finder) }
            permissions.refreshSystem()
            recorder.write(reason: "runtime-settings-applied")
            settingsDidCommit?(previous, current)
            stateDidChange?()
        }
    )
    lazy var recorder: RuntimeStateRecorder = RuntimeStateRecorder(
        settingsProvider: { [weak self] in self?.settingsSession.current },
        mouseService: mouseService, windowService: windowService,
        hotKeyService: hotKeyService, dragSnapService: dragSnapService
    )

    init(settingsModel: SettingsModel) {
        self.settingsModel = settingsModel
        let window = WindowRuntimeClient()
        let mouse = MouseRuntimeClient()
        host = RuntimeHostCoordinator(window: window, mouse: mouse, permissions: permissions)
        windowService = WindowManagementService(bridge: window)
        hotKeyService = GlobalHotKeyService(bridge: window)
        dragSnapService = WindowDragSnapService(bridge: window)
        mouseService = MouseScrollEnhancementService(bridge: mouse)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeRuntimeServiceChanges()
        settingsSession.start()
        permissions.refreshSystem()
    }

    func stop() {
        isStarted = false
        host.suspend()
        accessibilityPermissionMonitor.stop()
        settingsSession.stop()
        recorder.stop()
        serviceCancellables.removeAll()
    }

    func refreshRuntimeState(retryConnection: Bool = false) {
        guard isStarted else { return }
        if retryConnection { host.retryConnection() }
        host.refreshState()
        permissions.refreshSystem()
        stateDidChange?()
    }

    func checkState(completion: @escaping RuntimeHostCoordinator.StateCheckCompletion) {
        guard isStarted, committedSettings != nil else {
            completion(.failure(.failure(L10n.string(.Runtime.settingsNotLoaded))))
            return
        }
        permissions.refreshSystem()
        if let blocked = permissions.backgroundBlocker(),
           let settings = committedSettings,
           settings.windowManagement.isEnabled || settings.mouseEnhancement.isEnabled || settings.finder.menuConfiguration.isEnabled {
            completion(.failure(.failure(blocked.detail)))
            return
        }
        host.checkState { [weak self] result in
            guard let self else { return }
            permissions.refreshSystem()
            recorder.write(reason: "explicit-state-check")
            stateDidChange?()
            completion(result)
        }
    }

    func requestAccessibilityPermission() {
        host.requestAccessibilityPermission { [weak self] succeeded in
            guard succeeded else { return }
            self?.accessibilityPermissionMonitor.start(reason: "explicit-permission-request")
        }
    }

    func requestMenuInputPermission() {
        guard committedSettings?.windowManagement.isEnabled == true,
              Bundle.main.bundleURL.standardizedFileURL.path == ArcKitConstants.installedAppPath else { return }
        ProcessPermissions.requestInputListening()
        permissions.refreshSystem()
        stateDidChange?()
    }

    func openAccessibilitySettings() {
        SystemPrivacySettings.open(.accessibility)
        accessibilityPermissionMonitor.start(reason: "explicit-settings-open")
    }

    private lazy var accessibilityPermissionMonitor = AccessibilityPermissionMonitor(
        refresh: { [weak self] in self?.host.refreshState() },
        isTrusted: { [weak self] in
            guard let self, let settings = committedSettings,
                  settings.windowManagement.isEnabled || settings.mouseEnhancement.isEnabled else { return true }
            return permissions.accessibilityEvidence() == .granted
        },
        didStop: { [weak self] in self?.permissions.finishApprovalWait() }
    )

    private func observeRuntimeServiceChanges() {
        let rebuild: () -> Void = { [weak self] in
            self?.stateDidChange?()
            self?.recorder.schedule(reason: "runtime-service-changed")
        }
        permissions.objectWillChange.sink { _ in rebuild() }.store(in: &serviceCancellables)
        mouseService.objectWillChange
            .sink { _ in rebuild() }
            .store(in: &serviceCancellables)
        windowService.objectWillChange
            .sink { _ in rebuild() }
            .store(in: &serviceCancellables)
        hotKeyService.objectWillChange
            .sink { _ in rebuild() }
            .store(in: &serviceCancellables)
        dragSnapService.objectWillChange
            .sink { _ in rebuild() }
            .store(in: &serviceCancellables)
    }

}
