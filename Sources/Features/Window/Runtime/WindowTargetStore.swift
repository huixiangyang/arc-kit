import Foundation

/// 只保存成功捕获的 AX 目标；容量、过期和清空统一由此维护，不重新选择窗口。
struct WindowTargetStore {
    private struct Entry {
        let target: WindowActionTarget
        let expiresAt: Date
    }

    private var entries: [UUID: Entry] = [:]
    private let maximumCount = 8
    private let lifetime: TimeInterval = 120

    mutating func insert(_ target: WindowActionTarget, now: Date = Date()) -> UUID {
        entries = entries.filter { $0.value.expiresAt > now }
        if entries.count >= maximumCount,
           let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let id = UUID()
        entries[id] = Entry(target: target, expiresAt: now.addingTimeInterval(lifetime))
        return id
    }

    mutating func target(for id: UUID, now: Date = Date()) -> WindowActionTarget? {
        guard let entry = entries[id], entry.expiresAt > now else {
            entries.removeValue(forKey: id)
            return nil
        }
        return entry.target
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
