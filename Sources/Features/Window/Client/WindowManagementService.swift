import ArcKitPlatform
import ArcKitWindow
import Combine
import Foundation

/// 主 App 的窗口状态代理。真实 AX 读写只存在于 ArcKitRuntimeHost。
@MainActor
public final class WindowManagementService: ObservableObject {
    public enum State: Equatable {
        case stopped
        case waitingForAccessibility
        case running
        case failed(String)
    }

    private let bridge: WindowRuntimeClient
    private var cancellable: AnyCancellable?
    private var observedSceneReportID: UUID?
    private var lastSceneErrorAt: Date?
    public var userFeedbackHandler: ((String) -> Void)?
    @Published public private(set) var isApplyingScene = false
    @Published public private(set) var lastSceneError: String?

    public init(bridge: WindowRuntimeClient) {
        self.bridge = bridge
        observedSceneReportID = bridge.snapshot.lastSceneResult?.id
        cancellable = bridge.objectWillChange.sink { [weak self] _ in
            // bridge 的 objectWillChange 在 snapshot 写入前发布；延后一拍，
            // 确保菜单和诊断读取到 Agent 已提交的新状态。
            Task { @MainActor [weak self] in
                if let self, let report = self.bridge.snapshot.lastSceneResult, self.observedSceneReportID != report.id {
                    self.observedSceneReportID = report.id
                    if report.completedAt >= (self.lastSceneErrorAt ?? .distantPast) {
                        self.lastSceneError = nil
                        self.lastSceneErrorAt = nil
                    }
                }
                self?.objectWillChange.send()
            }
        }
    }

    public var state: State {
        switch bridge.snapshot.lifecycle {
        case .starting, .stopped: .stopped
        case .waitingForAccessibility: .waitingForAccessibility
        case .running: .running
        case .degraded, .safeMode, .unavailable:
            .failed(bridge.snapshot.lastResult?.userMessage ?? L10n.string(.WindowSettings.connectionUnavailable))
        }
    }

    public var lastResult: WindowManagementResult? { bridge.snapshot.lastResult }
    public var lastSceneResult: WindowSceneExecutionReport? { bridge.snapshot.lastSceneResult }
    public var sceneHotKeyFailures: [UUID: String] { bridge.snapshot.sceneHotKeyFailures }
    public var agentProcessID: Int32 { bridge.snapshot.processID }
    public var agentLaunchID: UUID { bridge.snapshot.launchID }
    public var accessibilityOperational: Bool { bridge.snapshot.accessibilityOperational }
    var runtimeSnapshot: WindowAgentRuntimeSnapshot { bridge.snapshot }
    var lastResponseAt: Date? { bridge.lastResponseAt }

    public var accessibilityTrusted: Bool { bridge.snapshot.accessibilityTrusted }

    public func refresh() {
        bridge.refresh()
    }



    public func captureWindowTarget(application: AppConfigurationCandidate? = nil, completion: @escaping (WindowTargetCaptureResult) -> Void) {
        bridge.captureWindowTarget(application: application, completion: completion)
    }

    public func fetchSceneInventory(completion: @escaping (Result<WindowSceneInventory, WindowSceneClientError>) -> Void) {
        bridge.fetchSceneInventory(completion: completion)
    }

    public func applyScene(id: UUID) {
        guard !isApplyingScene else { return }
        isApplyingScene = true
        lastSceneError = nil
        lastSceneErrorAt = nil
        bridge.applyScene(id: id) { [weak self] result in self?.finishSceneRequest(result) }
    }

    public func undoScene(token: UUID) {
        guard !isApplyingScene else { return }
        isApplyingScene = true
        lastSceneError = nil
        lastSceneErrorAt = nil
        bridge.undoScene(token: token) { [weak self] result in self?.finishSceneRequest(result) }
    }

    private func finishSceneRequest(_ result: Result<WindowSceneExecutionReport, WindowSceneClientError>) {
        isApplyingScene = false
        switch result {
        case .success:
            break
        case .failure(let error):
            lastSceneError = error.message
            lastSceneErrorAt = Date()
            userFeedbackHandler?(error.message)
        }
    }

    public func configurableApplicationCandidate() -> AppConfigurationCandidate? {
        bridge.snapshot.configurableApplicationCandidate
    }

    public func reportFailure(_ message: String) {
        // 页面校验和目标不可用只反馈给用户，后台健康必须来自 Host 回执。
        userFeedbackHandler?(message)
    }

    func perform(_ action: WindowLayoutAction, target: WindowTargetCaptureResult) {
        switch target {
        case .ready(let id): perform(action, targetID: id)
        case .unavailable(let message): reportFailure(message)
        }
    }

    public func perform(_ action: WindowLayoutAction, targetID: UUID) {
        bridge.perform(action, targetID: targetID) { [weak self] result in
            if !result.succeeded, let message = result.userMessage {
                self?.userFeedbackHandler?(message)
            }
        }
    }
}
