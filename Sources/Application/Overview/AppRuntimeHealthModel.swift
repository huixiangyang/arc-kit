import ArcKitFinder
import Combine
import Foundation

/// Finder 检测按一次用户请求合并；昂贵的系统注册检查每轮只执行一次。
@MainActor
final class AppRuntimeHealthModel: ObservableObject {
    typealias FinderHealthProvider = @Sendable () async -> FinderExtensionStatusService.HealthStatus

    @Published private(set) var finderHealth: FinderExtensionStatusService.HealthStatus?
    @Published private(set) var isRefreshing = false
    let isPreview: Bool
    private var finderEnabled = true
    private let finderHealthProvider: FinderHealthProvider
    private var refreshTask: Task<Void, Never>?
    private var sequence = 0
    private var refreshAfterCurrent = false

    init(isPreview: Bool = false, finderHealthProvider: FinderHealthProvider? = nil) {
        self.isPreview = isPreview
        self.finderHealthProvider = finderHealthProvider ?? {
            await FinderExtensionStatusService.refreshHealth()
        }
    }

    func setFinderEnabled(_ enabled: Bool) {
        guard finderEnabled != enabled else { return }
        finderEnabled = enabled
        sequence += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshAfterCurrent = false
        isRefreshing = false
        finderHealth = nil
        if enabled { refresh() }
    }

    func refresh(force: Bool = false) {
        // 独立 Debug 不查询安装版、不发送扩展通知，也不把未连接显示成权限失败。
        guard !isPreview, finderEnabled else { return }
        guard !isRefreshing else { return }
        if !force, let checkedAt = finderHealth?.checkedAt, Date().timeIntervalSince(checkedAt) < 10 { return }
        isRefreshing = true
        sequence += 1
        let current = sequence
        let provider = finderHealthProvider
        refreshTask = Task { [weak self] in
            let result = await provider()
            guard let self, !Task.isCancelled, current == sequence else { return }
            finderHealth = result
            isRefreshing = false
            refreshTask = nil
            if refreshAfterCurrent {
                refreshAfterCurrent = false
                refresh(force: true)
            }
        }
    }

    func refreshAfterRepair() {
        if isRefreshing { refreshAfterCurrent = true }
        else { refresh(force: true) }
    }
}
