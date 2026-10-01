import Combine

/// 仅转交成功提交的配置。组合根决定哪些消费者需要更新，订阅本身不再维护业务启停副本。
@MainActor
final class RuntimeSettingsSession {
    private(set) var current: AppSettings?
    private let model: SettingsModel
    private let didCommit: (AppSettings?, AppSettings) -> Void
    private var subscription: AnyCancellable?

    init(model: SettingsModel, didCommit: @escaping (AppSettings?, AppSettings) -> Void) {
        self.model = model
        self.didCommit = didCommit
    }

    func start() {
        guard subscription == nil else { return }
        // 同步消费发布的事件值，不能读 willSet 中尚未更新的属性。
        subscription = model.$committedSettings.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] settings in
                guard let self, self.current != settings else { return }
                let previous = self.current
                self.current = settings
                self.didCommit(previous, settings)
            }
    }

    func stop() {
        subscription = nil
        current = nil
    }
}
