import Combine

/// 不持有第二份草稿。读取和写入均回到应用的同一个配置事务，保留校验、撤销和保存门禁。
@MainActor
final class SettingsEditor<Value: Equatable>: ObservableObject {
    typealias Edit = (inout Value) -> Void
    private let read: () -> Value
    private let readCommitted: () -> Value?
    private let commit: (String?, String?, Edit) -> Void
    private var observation: AnyCancellable?

    var settings: Value { read() }
    var hasUncommittedChanges: Bool { readCommitted() != settings }

    init(changes: ObservableObjectPublisher, read: @escaping () -> Value,
         committed: @escaping () -> Value?,
         update: @escaping (String?, String?, Edit) -> Void) {
        self.read = read
        self.readCommitted = committed
        self.commit = update
        observation = changes.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func update(actionName: String? = nil, coalescingKey: String? = nil, _ edit: Edit) {
        commit(actionName, coalescingKey, edit)
    }
}
