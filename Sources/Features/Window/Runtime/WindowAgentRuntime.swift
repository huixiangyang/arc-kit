import ArcKitPlatform
import ArcKitWindow
import ApplicationServices
@preconcurrency import AppKit
import Combine
import Foundation

private final class WorkspaceActivationObserverToken: @unchecked Sendable {
    let rawValue: NSObjectProtocol

    init(_ rawValue: NSObjectProtocol) {
        self.rawValue = rawValue
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(rawValue)
    }
}

@MainActor
public final class WindowAgentRuntime: ObservableObject {
    public enum State: Equatable {
        case stopped
        case waitingForAccessibility
        case running
        case failed(String)
    }

    @Published public private(set) var state: State = .stopped
    @Published public private(set) var lastResult: WindowManagementResult?
    @Published public private(set) var lastSceneResult: WindowSceneExecutionReport?
    @Published public private(set) var accessibilityOperational = false

    public var userFeedbackHandler: ((String) -> Void)?

    private let engine = WindowLayoutEngine()
    private let accessibilityClient: WindowAccessibilityClient
    private let accessibilityTrusted: () -> Bool
    private let screenVisibleFramesProvider: @MainActor () -> [CGRect]
    private let screenFullFramesProvider: @MainActor () -> [CGRect]
    private let verifier: WindowResultVerifier
    private let sceneRuntime: WindowSceneRuntime
    private var actionInFlight = false
    private var configurationGeneration = 0
    private var settings: WindowManagementSettings = .defaults
    private var restoreHistory = WindowRestoreHistory(maximumCount: 64)
    private var workspaceActivationObserver: WorkspaceActivationObserverToken?
    private var lastExternalApplication: ExternalApplicationSnapshot?
    private var capturedTargets = WindowTargetStore()

    public convenience init(hostLaunchID: UUID = UUID()) {
        self.init(
            accessibilityClient: SystemWindowAccessibilityClient(),
            accessibilityTrusted: ProcessPermissions.accessibilityTrusted,
            screenVisibleFramesProvider: WindowAgentRuntime.accessibilityVisibleScreenFrames,
            screenFullFramesProvider: WindowAgentRuntime.accessibilityFullScreenFrames,
            observesWorkspaceActivation: true,
            sceneHostLaunchID: hostLaunchID
        )
    }

    init(
        accessibilityClient: WindowAccessibilityClient,
        accessibilityTrusted: @escaping () -> Bool,
        screenVisibleFramesProvider: @escaping @MainActor () -> [CGRect] = WindowAgentRuntime.accessibilityVisibleScreenFrames,
        screenFullFramesProvider: @escaping @MainActor () -> [CGRect] = WindowAgentRuntime.accessibilityFullScreenFrames,
        fullScreenVerificationStableInterval: TimeInterval = 0.8,
        observesWorkspaceActivation: Bool = false,
        sceneDisplaysProvider: @escaping @MainActor () -> [WindowSceneDisplay] = WindowSceneRuntime.displays,
        sceneHostLaunchID: UUID = UUID()
    ) {
        self.sceneRuntime = WindowSceneRuntime(client: accessibilityClient, displaysProvider: sceneDisplaysProvider, hostLaunchID: sceneHostLaunchID)
        self.accessibilityClient = accessibilityClient
        self.accessibilityTrusted = accessibilityTrusted
        self.screenVisibleFramesProvider = screenVisibleFramesProvider
        self.screenFullFramesProvider = screenFullFramesProvider
        self.verifier = WindowResultVerifier(accessibilityClient: accessibilityClient, fullScreenVerificationStableInterval: fullScreenVerificationStableInterval)
        if observesWorkspaceActivation {
            observeWorkspaceActivation()
        }
    }

    public func start(settings: WindowManagementSettings) async {
        configurationGeneration += 1
        capturedTargets.removeAll()
        let generation = configurationGeneration
        self.settings = settings
        sceneRuntime.updateScenes(settings.scenes)
        guard settings.isEnabled else {
            accessibilityOperational = false
            state = .stopped
            ArcKitLog.append("window management stopped reason=settings-disabled")
            return
        }
        guard accessibilityTrusted() else {
            accessibilityOperational = false
            state = .waitingForAccessibility
            ArcKitLog.append("window management waiting reason=accessibility-not-trusted")
            return
        }
        let operational = await probeAccessibilityOperational()
        guard generation == configurationGeneration, self.settings.isEnabled else { return }
        guard operational else {
            let message = WindowManagementExecutionError.accessibilityAPIUnavailable.localizedDescription
            state = .failed(message)
            return
        }
        guard generation == configurationGeneration, self.settings.isEnabled else { return }
        state = .running
        ArcKitLog.append("window management running gap=\(Int(settings.windowGap))")
    }

    @discardableResult
    public func probeAccessibilityOperational() async -> Bool {
        let generation = configurationGeneration
        guard accessibilityTrusted() else {
            updateAccessibilityOperational(false)
            return false
        }
        do {
            try await accessibilityClient.validateAccessibilityOperational()
            guard generation == configurationGeneration, settings.isEnabled else { return false }
            updateAccessibilityOperational(true)
            return true
        } catch {
            guard generation == configurationGeneration, settings.isEnabled else { return false }
            let failureState = State.failed(WindowManagementExecutionError.accessibilityAPIUnavailable.localizedDescription)
            let shouldLog = accessibilityOperational || state != failureState
            updateAccessibilityOperational(false)
            if shouldLog {
                ArcKitLog.append("window management probe failed reason=accessibility-api-unavailable error=\(error.localizedDescription)")
            }
            return false
        }
    }

    public func stop() {
        configurationGeneration += 1
        capturedTargets.removeAll()
        settings.isEnabled = false
        accessibilityOperational = false
        state = .stopped
        ArcKitLog.append("window management stopped reason=manual-stop")
    }

    func captureWindowTarget(application: AppConfigurationCandidate? = nil) async throws -> WindowTargetCaptureResult {
        let generation = configurationGeneration
        let target: WindowActionTarget?
        let failure: String?
        do {
            if let application {
                // 捕获来源由点击时固定；XPC 排队期间前台变化不能把目标换成另一个应用。
                guard !isArcKitApplication(application),
                      !accessibilityClient.isApplicationTerminated(pid: application.processIdentifier) else {
                    throw WindowManagementExecutionError.captureApplicationUnavailable
                }
                target = try await accessibilityClient.windowTarget(for: application.processIdentifier, bundleIdentifier: application.bundleIdentifier)
            } else {
                target = try await frontmostWindowTarget()
            }
            failure = target == nil ? L10n.string(.WindowRuntime.actionNoEligibleWindow) : nil
        } catch {
            target = nil
            failure = error.localizedDescription
        }
        guard generation == configurationGeneration else { throw CancellationError() }
        guard let target else {
            let message = failure ?? L10n.string(.WindowRuntime.actionNoEligibleWindow)
            ArcKitLog.append("window target unavailable origin=\(application?.processIdentifier ?? 0) reason=\(message)")
            return .unavailable(message)
        }
        // 失败不进入令牌表；UI 必须拿到 ready 才能执行，AX 引用不离开 Host。
        let id = capturedTargets.insert(target)
        ArcKitLog.append("window target captured id=\(id) pid=\(target.pid) window=\(target.restoreKey.windowNumber ?? 0)")
        return .ready(id)
    }

    func perform(_ action: WindowLayoutAction, capturedTargetID: UUID) async -> WindowManagementResult {
        guard let target = capturedTargets.target(for: capturedTargetID) else {
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionTargetWindowExpiredSelectAgain)))
        }
        guard !accessibilityClient.isApplicationTerminated(pid: target.pid) else {
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionTargetAppExitedSelectWindowAgain)))
        }
        ArcKitLog.append("window target executing id=\(capturedTargetID) pid=\(target.pid) window=\(target.restoreKey.windowNumber ?? 0)")
        return await perform(action, preferredTarget: target)
    }

    func sceneInventory(deadline: Date) async throws -> WindowSceneInventory {
        guard !actionInFlight else { throw WindowSceneRuntimeError.busy }
        guard sceneAvailable else { throw WindowSceneRuntimeError.unavailable }
        actionInFlight = true
        defer { actionInFlight = false }
        let generation = configurationGeneration
        return try await sceneRuntime.inventory { self.sceneRequestValid(generation: generation, deadline: deadline) }
    }

    @discardableResult
    func applyScene(_ sceneID: UUID, deadline: Date = Date().addingTimeInterval(30)) async throws -> WindowSceneExecutionReport {
        guard !actionInFlight else { throw WindowSceneRuntimeError.busy }
        guard sceneAvailable else { throw WindowSceneRuntimeError.unavailable }
        guard let scene = settings.scenes.first(where: { $0.id == sceneID }) else { throw WindowSceneRuntimeError.missingScene }
        actionInFlight = true
        defer { actionInFlight = false }
        let generation = configurationGeneration
        let report = await sceneRuntime.apply(scene, settings: settings) {
            self.sceneRequestValid(generation: generation, deadline: deadline)
        }
        lastSceneResult = report
        return report
    }

    func undoScene(_ token: UUID, deadline: Date) async throws -> WindowSceneExecutionReport {
        guard !actionInFlight else { throw WindowSceneRuntimeError.busy }
        guard sceneAvailable else { throw WindowSceneRuntimeError.unavailable }
        actionInFlight = true
        defer { actionInFlight = false }
        let generation = configurationGeneration
        let report = try await sceneRuntime.undo(token, settings: settings) {
            self.sceneRequestValid(generation: generation, deadline: deadline)
        }
        lastSceneResult = report
        return report
    }

    private var sceneAvailable: Bool { settings.isEnabled && accessibilityTrusted() && accessibilityOperational }

    private func sceneRequestValid(generation: Int, deadline: Date) -> Bool {
        generation == configurationGeneration && sceneAvailable && Date() < deadline && !Task.isCancelled
    }

    public func configurableApplicationCandidate() -> AppConfigurationCandidate? {
        let frontmost = accessibilityClient.frontmostApplication().flatMap { app in
            isArcKitApplication(app) ? nil : app
        }
        return AppConfigurationCandidateResolver.resolve(
            frontmost: frontmost,
            lastExternal: validLastExternalApplication()?.snapshot,
            currentBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    public func reportFailure(_ message: String) {
        _ = finish(.init(succeeded: false, userMessage: message))
    }

    @discardableResult
    public func perform(_ action: WindowLayoutAction) async -> WindowManagementResult {
        await perform(action, preferredTarget: nil)
    }

    @discardableResult
    func perform(_ action: WindowLayoutAction, preferredTarget: WindowActionTarget?) async -> WindowManagementResult {
        guard !actionInFlight else { return .init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionWindowActionRunningRetry)) }
        actionInFlight = true
        defer { actionInFlight = false }
        let generation = configurationGeneration
        guard settings.isEnabled else {
            state = .stopped
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.connectionWindowManagementOff)))
        }
        guard accessibilityTrusted() else {
            state = .waitingForAccessibility
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionAccessibilityRequiredArrangeWindows)))
        }
        guard accessibilityOperational else {
            let message = WindowManagementExecutionError.accessibilityAPIUnavailable.localizedDescription
            state = .failed(message)
            return finish(.init(
                succeeded: false,
                userMessage: message
            ))
        }
        let resolvedTarget: WindowActionTarget?
        do {
            if let preferredTarget {
                resolvedTarget = preferredTarget
            } else {
                resolvedTarget = try await frontmostWindowTarget()
            }
        } catch let error as WindowManagementExecutionError {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finishExecutionError(error)
        } catch {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionTargetResolutionFailed(String(describing: error.localizedDescription)))))
        }
        guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
        guard let target = resolvedTarget else {
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionCurrentAppAdjustableWindowMissing)))
        }
        guard !isArcKitProcess(pid: target.pid, bundleIdentifier: target.bundleIdentifier) else {
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionSelectExternalWindowArrangeFirst)))
        }
        if settings.isExcluded(bundleIdentifier: target.bundleIdentifier) {
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionCurrentAppExcludedWindow)))
        }

        if action == .fullScreen {
            return await performFullScreen(on: target, generation: generation)
        }

        do {
            try await accessibilityClient.validateWindowAdjustable(target)
            let currentFrame = try await accessibilityClient.frame(of: target)
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            let screens = screenVisibleFramesProvider()
            let previousFrame = restoreHistory.frame(for: target.restoreKey)
            if action == .restore, previousFrame == nil {
                throw WindowLayoutEngineError.missingRestoreFrame
            }
            let currentFrameVisibleScreen = screenFrame(containing: currentFrame, screens: screens)
            guard let currentScreen = currentFrameVisibleScreen
                    ?? restoreScreenFrame(for: action, previousFrame: previousFrame, screens: screens)
            else {
                return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionDisplayMissing)))
            }
            let input = WindowLayoutInput(
                action: action,
                currentFrame: currentFrame,
                currentScreenVisibleFrame: currentScreen,
                allScreenVisibleFrames: screens,
                previousFrame: previousFrame,
                gap: settings.windowGap,
                displayNavigationStrategy: settings.displayNavigationStrategy
            )
            let targetFrame = try engine.frame(for: input)
            let frameChanged = !verifier.framesMatch(currentFrame, targetFrame)
            if !frameChanged {
                state = .running
                ArcKitLog.append(
                    "window action no-op action=\(action.rawValue) app=\(target.bundleIdentifier ?? "-") identity=\(target.restoreKey.diagnosticDescription) frame=\(rectDescription(currentFrame))"
                )
                return finish(.init(
                    succeeded: true,
                    diagnosticFields: [
                        "action": action.rawValue,
                        "bundleIdentifier": target.bundleIdentifier ?? "-",
                        "windowTitle": target.restoreKey.title,
                        "windowIdentity": target.restoreKey.diagnosticDescription,
                        "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)),\(Int(targetFrame.width)),\(Int(targetFrame.height))",
                        "noOp": "true",
                    ]
                ))
            }
            guard generation == configurationGeneration, settings.isEnabled else { throw CancellationError() }
            try await accessibilityClient.setFrame(targetFrame, for: target)
            let verifiedFrame = try await verifier.verifiedFrame(for: target, expected: targetFrame)
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            let constrainedSuccess = !verifier.framesMatch(verifiedFrame, targetFrame)
                && verifier.frameWasConstrainedButApplied(
                    actual: verifiedFrame,
                    expected: targetFrame,
                    original: currentFrame,
                    action: action,
                    screen: currentScreen
                )
            guard verifier.framesMatch(verifiedFrame, targetFrame) || constrainedSuccess else {
                throw WindowManagementExecutionError.frameVerificationFailed(
                    expected: rectDescription(targetFrame),
                    actual: rectDescription(verifiedFrame)
                )
            }
            // 只有真实移动/缩放后才记住执行前位置；重复按同一布局不能把原始恢复历史覆盖成自身。
            // restore 从离屏状态救回时也不能把离屏 frame 重新写入历史。
            if frameChanged && (action != .restore || currentFrameVisibleScreen != nil) {
                restoreHistory.remember(currentFrame, for: target.restoreKey)
            }
            state = .running
            ArcKitLog.append(
                "window action success action=\(action.rawValue) app=\(target.bundleIdentifier ?? "-") identity=\(target.restoreKey.diagnosticDescription) source=\(rectDescription(currentFrame)) target=\(rectDescription(targetFrame)) verified=\(rectDescription(verifiedFrame))"
            )
            return finish(.init(
                succeeded: true,
                diagnosticFields: [
                    "action": action.rawValue,
                    "bundleIdentifier": target.bundleIdentifier ?? "-",
                    "windowTitle": target.restoreKey.title,
                    "windowIdentity": target.restoreKey.diagnosticDescription,
                    "targetFrame": "\(Int(targetFrame.origin.x)),\(Int(targetFrame.origin.y)),\(Int(targetFrame.width)),\(Int(targetFrame.height))",
                    "verifiedFrame": "\(Int(verifiedFrame.origin.x)),\(Int(verifiedFrame.origin.y)),\(Int(verifiedFrame.width)),\(Int(verifiedFrame.height))",
                    "constrained": constrainedSuccess ? "true" : "false",
                ]
            ))
        } catch WindowLayoutEngineError.missingRestoreFrame {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionPreviousWindowPositionRestoreMissing)))
        } catch WindowLayoutEngineError.missingDisplay {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionOtherDisplayFoundMissing)))
        } catch let error as WindowManagementExecutionError {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finishExecutionError(error)
        } catch {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionWindowAdjustmentFailed(String(describing: error.localizedDescription)))))
        }
    }

    private func performFullScreen(on target: WindowActionTarget, generation: Int) async -> WindowManagementResult {
        do {
            let previousState = try await accessibilityClient.isWindowFullScreen(target)
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            let expectedState = !previousState
            try await accessibilityClient.setWindowFullScreen(expectedState, for: target)
            let verifiedState = try await verifier.verifiedFullScreenState(for: target, expected: expectedState)
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            guard verifiedState == expectedState else {
                throw WindowManagementExecutionError.fullScreenVerificationFailed(
                    expected: expectedState,
                    actual: verifiedState
                )
            }
            state = .running
            ArcKitLog.append(
                "window action success action=\(WindowLayoutAction.fullScreen.rawValue) " +
                "app=\(target.bundleIdentifier ?? "-") identity=\(target.restoreKey.diagnosticDescription) " +
                "fullScreenBefore=\(previousState) fullScreenAfter=\(verifiedState)"
            )
            return finish(.init(
                succeeded: true,
                diagnosticFields: [
                    "action": WindowLayoutAction.fullScreen.rawValue,
                    "bundleIdentifier": target.bundleIdentifier ?? "-",
                    "windowTitle": target.restoreKey.title,
                    "windowIdentity": target.restoreKey.diagnosticDescription,
                    "fullScreenBefore": String(previousState),
                    "fullScreenAfter": String(verifiedState),
                ]
            ))
        } catch let error as WindowManagementExecutionError {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finishExecutionError(error)
        } catch {
            guard generation == configurationGeneration, settings.isEnabled else { return cancelledResult }
            return finish(.init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionFullScreenChangeFailed(String(describing: error.localizedDescription)))))
        }
    }

    func snapAction(at point: CGPoint) -> WindowLayoutAction? {
        guard settings.isEnabled, settings.dragSnapEnabled else { return nil }
        let fullFrames = screenFullFramesProvider()
        guard let screen = fullFrames.first(where: { $0.containsInclusive(point) }) else {
            return nil
        }
        return engine.snapAction(for: point, visibleFrame: screen, allVisibleFrames: fullFrames)
    }

    func snapPreviewFrame(for action: WindowLayoutAction, at point: CGPoint, currentFrame: CGRect) -> WindowSnapPreviewFrame? {
        guard settings.isEnabled, settings.dragSnapEnabled else { return nil }
        let visibleFrames = screenVisibleFramesProvider()
        let fullFrames = screenFullFramesProvider()
        guard let screenIndex = fullFrames.firstIndex(where: { $0.containsInclusive(point) }),
              visibleFrames.indices.contains(screenIndex)
        else {
            return nil
        }
        let screen = visibleFrames[screenIndex]
        guard let accessibilityFrame = try? engine.frame(for: WindowLayoutInput(
            action: action,
            currentFrame: currentFrame,
            currentScreenVisibleFrame: screen,
            allScreenVisibleFrames: visibleFrames,
            gap: settings.windowGap,
            displayNavigationStrategy: settings.displayNavigationStrategy
        )) else {
            return nil
        }
        return WindowSnapPreviewFrame(
            accessibilityFrame: accessibilityFrame,
            appKitFrame: Self.coordinateSpace().accessibilityToAppKit(accessibilityFrame)
        )
    }

    func windowTarget(at point: CGPoint) async -> WindowHitTestTarget? {
        guard !actionInFlight, settings.isEnabled,
              accessibilityTrusted(),
              accessibilityOperational
        else {
            return nil
        }
        guard let candidate = await accessibilityClient.windowTarget(at: point),
              !settings.isExcluded(bundleIdentifier: candidate.target.bundleIdentifier)
        else { return nil }
        return candidate
    }

    func frame(for target: WindowActionTarget) async throws -> CGRect {
        try await accessibilityClient.frame(of: target)
    }

    private var cancelledResult: WindowManagementResult { .init(succeeded: false, userMessage: L10n.string(.WindowRuntime.actionWindowConfigurationChangedActionCancelled)) }

    private func finishExecutionError(_ error: WindowManagementExecutionError) -> WindowManagementResult {
        if case .accessibilityAPIUnavailable = error {
            accessibilityOperational = false
            state = .failed(error.localizedDescription)
        }
        return finish(.init(succeeded: false, userMessage: error.localizedDescription))
    }

    private func finish(_ result: WindowManagementResult) -> WindowManagementResult {
        lastResult = result
        if let message = result.userMessage, !result.succeeded {
            // 生命周期状态只描述服务是否真的可运行；没有目标窗口、窗口不支持等单次失败
            // 由 lastResult 展示，不能伪装成权限或服务故障并连带禁用全部快捷操作。
            ArcKitLog.append("window action failed message=\(message)")
            userFeedbackHandler?(message)
        }
        return result
    }

    private func updateAccessibilityOperational(_ value: Bool) {
        guard accessibilityOperational != value else { return }
        accessibilityOperational = value
    }

    private func frontmostWindowTarget() async throws -> WindowActionTarget? {
        guard let app = accessibilityClient.frontmostApplication() else {
            return try await lastExternalWindowTarget()
        }
        if isArcKitApplication(app) {
            // 菜单栏点击会让 Arc Kit 自己短暂成为前台；此时应继续操作用户刚才的外部窗口。
            return try await lastExternalWindowTarget()
        }
        rememberExternalApplication(app)
        return try await accessibilityClient.windowTarget(for: pid_t(app.processIdentifier), bundleIdentifier: app.bundleIdentifier)
    }

    private func screenFrame(containing frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard let screen = screens.max(by: { lhs, rhs in
            lhs.intersection(frame).area < rhs.intersection(frame).area
        }), screen.intersection(frame).area > 0 else {
            return nil
        }
        return screen
    }

    private func restoreScreenFrame(for action: WindowLayoutAction, previousFrame: CGRect?, screens: [CGRect]) -> CGRect? {
        guard action == .restore, let previousFrame else { return nil }
        // 当前窗口可能因外接屏变化或系统异常落到可见区域外；恢复动作应优先用历史可见位置救回窗口。
        return screenFrame(containing: previousFrame, screens: screens)
    }

    private func rectDescription(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    static func accessibilityVisibleScreenFrames() -> [CGRect] {
        let screens = NSScreen.screens
        let coordinateSpace = ArcKitScreenCoordinateSpace(screenFrames: screens.map(\.frame))
        return screens.map { coordinateSpace.appKitToAccessibility($0.visibleFrame) }
    }

    static func accessibilityFullScreenFrames() -> [CGRect] {
        let screens = NSScreen.screens
        let coordinateSpace = ArcKitScreenCoordinateSpace(screenFrames: screens.map(\.frame))
        return screens.map { coordinateSpace.appKitToAccessibility($0.frame) }
    }

    static func coordinateSpace() -> ArcKitScreenCoordinateSpace {
        ArcKitScreenCoordinateSpace(screenFrames: NSScreen.screens.map(\.frame))
    }

    private func observeWorkspaceActivation() {
        let rawObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else { return }
                self?.rememberExternalApplication(AppConfigurationCandidate(
                    displayName: app.localizedName ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: Int32(app.processIdentifier)
                ))
            }
        }
        workspaceActivationObserver = WorkspaceActivationObserverToken(rawObserver)
    }

    private func rememberExternalApplication(_ app: AppConfigurationCandidate) {
        guard !isArcKitApplication(app),
              !accessibilityClient.isApplicationTerminated(pid: pid_t(app.processIdentifier))
        else { return }
        lastExternalApplication = ExternalApplicationSnapshot(snapshot: app)
    }

    private func lastExternalWindowTarget() async throws -> WindowActionTarget? {
        guard let snapshot = validLastExternalApplication() else {
            return nil
        }
        ArcKitLog.append("window target fallback previous app bundle=\(snapshot.bundleIdentifier ?? "-") pid=\(snapshot.processIdentifier)")
        return try await accessibilityClient.windowTarget(
            for: snapshot.processIdentifier,
            bundleIdentifier: snapshot.bundleIdentifier
        )
    }

    private func validLastExternalApplication() -> ExternalApplicationSnapshot? {
        guard let snapshot = lastExternalApplication else { return nil }
        if accessibilityClient.isApplicationTerminated(pid: snapshot.processIdentifier) {
            ArcKitLog.append("window target fallback dropped terminated app bundle=\(snapshot.bundleIdentifier ?? "-") pid=\(snapshot.processIdentifier)")
            lastExternalApplication = nil
            return nil
        }
        return snapshot
    }

    private func isArcKitApplication(_ app: AppConfigurationCandidate) -> Bool {
        isArcKitProcess(pid: pid_t(app.processIdentifier), bundleIdentifier: app.bundleIdentifier)
    }

    private func isArcKitProcess(pid: pid_t, bundleIdentifier: String?) -> Bool {
        let firstPartyBundleIdentifiers: Set<String> = [
            ArcKitConstants.appBundleIdentifier,
            ArcKitConstants.runtimeHostBundleIdentifier,
            ArcKitConstants.finderExtensionBundleIdentifier,
        ]
        return bundleIdentifier.map(firstPartyBundleIdentifiers.contains) == true
            || pid == ProcessInfo.processInfo.processIdentifier
    }
}

private struct ExternalApplicationSnapshot {
    var snapshot: AppConfigurationCandidate

    var processIdentifier: pid_t { pid_t(snapshot.processIdentifier) }
    var bundleIdentifier: String? { snapshot.bundleIdentifier }
}
