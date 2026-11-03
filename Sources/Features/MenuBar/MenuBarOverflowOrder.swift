#if DEBUG
import Foundation

/// macOS 27 把位置集中保存在 MenuBarAgent 的共享偏好中，不再读取应用自己的位置键。
/// 读取本应用的两个锚点，只登记六个占位；每次合并最新表，保留其他应用和系统模块的条目。
struct MenuBarOverflowOrder {
    let prefix: String
    private let domain: CFString
    private let key = "TrailingItemPreferredPositions" as CFString

    init(namespace: String, owner: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        prefix = "status:\(owner)::\(namespace)."
        domain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar").path as CFString
    }

    func hasSavedAnchors() throws -> Bool {
        let positions = try read()
        if positions[prefix + "toggle"] == nil && positions[prefix + "hidden"] == nil { return false }
        guard Self.hasOrderedAnchors(positions, prefix: prefix) else { throw MenuBarPartitionError.overflowOrderUnavailable }
        return true
    }

    func prepareSpacers(count: Int) throws {
        try update { positions in
            positions = try Self.positionSpacers(in: positions, prefix: prefix, count: count)
        }
    }

    static func hasOrderedAnchors(_ positions: [String: Double], prefix: String) -> Bool {
        guard let control = positions[prefix + "toggle"], let boundary = positions[prefix + "hidden"] else { return false }
        return control.isFinite && boundary.isFinite && control >= 0 && boundary > control
    }

    static func positionSpacers(in positions: [String: Double], prefix: String, count: Int) throws -> [String: Double] {
        guard count > 0, hasOrderedAnchors(positions, prefix: prefix),
              let control = positions[prefix + "toggle"], let boundary = positions[prefix + "hidden"] else {
            throw MenuBarPartitionError.overflowOrderUnavailable
        }
        // 分界与固定入口之间的槽位依原生登记顺序插入；仅改本应用的位置键。
        let nearest = control
        let step = (boundary - control) / Double(count + 1)
        var result = positions
        for index in 0..<count {
            result[prefix + "overflow.spacer.\(index)"] = nearest + step * Double(index + 1)
        }
        return result
    }

    private func read() throws -> [String: Double] {
        guard CFPreferencesAppSynchronize(domain),
              let positions = CFPreferencesCopyAppValue(key, domain) as? [String: Double] else {
            throw MenuBarPartitionError.overflowOrderUnavailable
        }
        return positions
    }

    private func update(_ change: (inout [String: Double]) throws -> Void) throws {
        let latest = try read()
        var updated = latest
        try change(&updated)
        guard updated != latest else { return }
        CFPreferencesSetAppValue(key, updated as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain),
              let readback = CFPreferencesCopyAppValue(key, domain) as? [String: Double],
              updated.filter({ $0.key.hasPrefix(prefix) }).allSatisfy({ readback[$0.key] == $0.value }) else {
            throw MenuBarPartitionError.overflowOrderUnavailable
        }
    }
}

#endif
