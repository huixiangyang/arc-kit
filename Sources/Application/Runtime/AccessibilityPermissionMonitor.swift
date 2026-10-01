import ArcKitPlatform
import Foundation

@MainActor
final class AccessibilityPermissionMonitor {
    private let refresh: () -> Void
    private let isTrusted: () -> Bool
    private let didStop: () -> Void
    private var timer: Timer?
    private var deadline: Date?
    private(set) var isMonitoring = false

    init(
        refresh: @escaping () -> Void,
        isTrusted: @escaping () -> Bool,
        didStop: @escaping () -> Void
    ) {
        self.refresh = refresh
        self.isTrusted = isTrusted
        self.didStop = didStop
    }

    func start(reason: String) {
        if isTrusted() {
            stop()
            return
        }
        guard timer == nil else { return }
        isMonitoring = true
        deadline = Date().addingTimeInterval(60)
        ArcKitLog.append("accessibility permission monitor started reason=\(reason)")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOnce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard timer != nil || isMonitoring else { return }
        timer?.invalidate()
        timer = nil
        deadline = nil
        isMonitoring = false
        didStop()
        ArcKitLog.append("accessibility permission monitor stopped")
    }

    func pollOnce() {
        guard isMonitoring else { return }
        // 用户离开授权流程后停止检查，不让未授权状态造成永久后台轮询。
        guard let deadline, Date() < deadline else { stop(); return }
        guard isTrusted() else {
            refresh()
            return
        }
        // 只等待授权事实；窗口可操作性由功能健康检测负责，不延长或重启授权轮询。
        ArcKitLog.append("accessibility permission monitor trusted")
        stop()
    }
}
