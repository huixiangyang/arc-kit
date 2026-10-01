import ArcKitFinder
import Foundation

/// Finder 会重建菜单项并改写 identifier、丢弃 representedObject。
/// 只传递 tag，动作和目标成对保存在扩展内；不按标题或最近菜单猜目标。
enum FinderMenuActionRegistry {
    static let maxEntries = 512

    struct Registration: Equatable, Sendable {
        var descriptor: FinderActionDescriptor
        var target: FinderContextCollector.ActionTargetSnapshot
    }

    private static let storage = Storage(capacity: maxEntries)

    @discardableResult
    static func register(
        _ descriptor: FinderActionDescriptor,
        target: FinderContextCollector.ActionTargetSnapshot
    ) -> Int {
        return storage.register(Registration(
            descriptor: descriptor,
            target: target
        ))
    }

    static func registration(forTag tag: Int) -> Registration? {
        guard tag > 0 else { return nil }
        return storage.registration(forTag: tag)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity: Int
        private var nextTag = 1
        private var registrationsByTag: [Int: Registration] = [:]
        private var insertionOrder: [Int] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        func register(_ registration: Registration) -> Int {
            lock.lock()
            defer { lock.unlock() }
            // 编号不复用，迟到回调只能失效，不能命中新菜单的目标。
            guard nextTag < Int.max else { return 0 }
            let tag = nextTag
            nextTag += 1
            registrationsByTag[tag] = registration
            insertionOrder.append(tag)
            trimIfNeeded()
            return tag
        }

        func registration(forTag tag: Int) -> Registration? {
            lock.lock()
            defer { lock.unlock() }
            return registrationsByTag[tag]
        }

        private func trimIfNeeded() {
            while insertionOrder.count > capacity {
                let removed = insertionOrder.removeFirst()
                registrationsByTag.removeValue(forKey: removed)
            }
        }
    }
}
