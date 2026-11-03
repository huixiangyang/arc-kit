import ArcKitPlatform
import Foundation

enum MenuBarArrangementError: Error, LocalizedError {
    case unsupported, collectionRequired, unavailable, changed, invalidOrder, unconfirmed
    case saveFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.string(.MenuBar.arrangeUnsupported)
        case .collectionRequired: L10n.string(.MenuBar.arrangeEnableCollection)
        case .unavailable: L10n.string(.MenuBar.overflowOrderUnavailable)
        case .changed: L10n.string(.MenuBar.arrangeChanged)
        case .invalidOrder: L10n.string(.MenuBar.arrangeInvalidOrder)
        case .unconfirmed: L10n.string(.MenuBar.arrangeUnconfirmed)
        case .saveFailed(let message): message
        }
    }
}

/// macOS 27 原生位置表是排列的唯一持久化来源；编排不再另存一份 SQLite 排序。
struct MenuBarSystemPositions {
    private let domain = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar").path as CFString
    private let key = "TrailingItemPreferredPositions" as CFString

    func read() throws -> [String: Double] {
        guard CFPreferencesAppSynchronize(domain),
              let positions = CFPreferencesCopyAppValue(key, domain) as? [String: Double] else {
            throw MenuBarArrangementError.unavailable
        }
        return positions
    }

    func write(_ replacements: [String: Double], expecting expected: [String: Double]) throws {
        let latest = try read()
        let updated = try Self.merging(latest, replacements: replacements, expected: expected)
        CFPreferencesSetAppValue(key, updated as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw MenuBarArrangementError.unavailable }
        let readback = try read()
        guard replacements.allSatisfy({ readback[$0.key] == $0.value }) else { throw MenuBarArrangementError.unconfirmed }
    }

    static func merging(_ latest: [String: Double], replacements: [String: Double], expected: [String: Double]) throws -> [String: Double] {
        guard expected.allSatisfy({ latest[$0.key] == $0.value }),
              replacements.allSatisfy({ $0.key.hasPrefix("status:") && expected[$0.key] != nil && $0.value.isFinite && $0.value >= 0 }) else {
            throw MenuBarArrangementError.changed
        }
        // 合并当前值，只写已确认身份的项目；不覆盖系统固定项、未知项或其他应用的新记录。
        return latest.merging(replacements) { _, replacement in replacement }
    }
}

enum MenuBarArrangementZone: String, CaseIterable, Identifiable {
    case collected, resident
    var id: Self { self }
    var title: String { L10n.string(self == .collected ? .MenuBar.arrangeCollected : .MenuBar.arrangeResident) }
}

struct MenuBarArrangementItem: Identifiable {
    enum Restriction { case system, identity, position }
    let id: String
    let observed: MenuBarObservedItem
    let position: Double?
    let restriction: Restriction?
    var isEditable: Bool { restriction == nil }
    var actionTitle: String {
        guard let label = observed.label, !label.isEmpty, label != observed.displayTitle else { return observed.displayTitle }
        return "\(observed.displayTitle) · \(label)"
    }
    var restrictionText: String {
        switch restriction {
        case .system: L10n.string(.MenuBar.arrangeSystemFixed)
        case .identity: L10n.string(.MenuBar.arrangeIdentityUnknown)
        case .position: L10n.string(.MenuBar.arrangePositionUnknown)
        case nil: ""
        }
    }
}

struct MenuBarArrangementLayout: Equatable {
    var collected: [String] = []
    var resident: [String] = []
    subscript(_ zone: MenuBarArrangementZone) -> [String] {
        get { zone == .collected ? collected : resident }
        set { if zone == .collected { collected = newValue } else { resident = newValue } }
    }
}

struct MenuBarArrangementMove {
    let itemID: String
    let zone: MenuBarArrangementZone
    /// nil 明确表示放到该区末尾；有参照项但已失效时必须拒绝，不能悄悄追加。
    let beforeID: String?
    var reorders: Bool = true
}

struct MenuBarArrangementSnapshot {
    let inventory: MenuBarInventory
    let positions: [String: Double]
    let collectedApplications: Set<String>
    let items: [MenuBarArrangementItem]
    let layout: MenuBarArrangementLayout

    init(inventory: MenuBarInventory, positions: [String: Double], owner: String, collectedApplications: Set<String>) throws {
        self.collectedApplications = collectedApplications
        guard inventory.accessibility == .granted else { throw MenuBarItemAccessError.permissionDenied }
        guard inventory.canUseGeometry else { throw MenuBarArrangementError.changed }
        self.inventory = inventory; self.positions = positions
        let visible = inventory.items.filter { $0.bundleIdentifier != owner }
        let owners = Dictionary(grouping: visible, by: { $0.bundleIdentifier ?? "" })
        var resolved: [MenuBarArrangementItem] = visible.map { item in
            func restricted(_ reason: MenuBarArrangementItem.Restriction) -> MenuBarArrangementItem {
                .init(id: "unresolved:\(item.id)", observed: item, position: nil, restriction: reason)
            }
            guard let bundle = item.bundleIdentifier, !MenuBarVisibilitySession.systemOwners.contains(bundle) else { return restricted(.system) }
            // 这里写系统持久化位置键，不向进程发送动作；root 应用缺少启动时间也可按唯一键编排。
            // 原生菜单点击仍由 MenuBarItemAccessSession 强制核对 PID 与启动时间。
            guard item.identityEligible else { return restricted(.identity) }
            let keyPrefix = "status:\(bundle)::"
            let candidates = positions.keys.filter { $0.hasPrefix(keyPrefix) }
            let exact = item.accessibilityIdentifier.map { keyPrefix + $0 }
            let key: String?
            if let exact, positions[exact] != nil { key = exact }
            else if owners[bundle]?.count == 1, candidates.count == 1 { key = candidates[0] }
            else { key = nil }
            guard let key, let position = positions[key], position.isFinite, position >= 0 else { return restricted(.identity) }
            return .init(id: key, observed: item, position: position, restriction: nil)
        }
        let counts = Dictionary(resolved.filter(\.isEditable).map { ($0.id, 1) }, uniquingKeysWith: +)
        let positionCounts = Dictionary(resolved.filter(\.isEditable).map { ($0.position!, 1) }, uniquingKeysWith: +)
        resolved = resolved.map { item in
            if counts[item.id, default: 0] > 1 {
                return .init(id: "unresolved:\(item.observed.id)", observed: item.observed, position: nil, restriction: .identity)
            }
            if let position = item.position, positionCounts[position, default: 0] > 1 {
                return .init(id: "unresolved:\(item.observed.id)", observed: item.observed, position: nil, restriction: .position)
            }
            return item
        }
        items = resolved
        let ordered = resolved.filter(\.isEditable).sorted { $0.position! > $1.position! }
        layout = .init(collected: ordered.filter { collectedApplications.contains($0.observed.bundleIdentifier!) }.map(\.id),
                       resident: ordered.filter { !collectedApplications.contains($0.observed.bundleIdentifier!) }.map(\.id))
    }

    var expectation: [String: Double] {
        let keys = Set(items.filter(\.isEditable).map(\.id))
        return positions.filter { keys.contains($0.key) }
    }

    func hasSameTargets(as other: Self) -> Bool {
        let current = Dictionary(uniqueKeysWithValues: items.filter(\.isEditable).map { ($0.id, $0.observed) })
        let previous = Dictionary(uniqueKeysWithValues: other.items.filter(\.isEditable).map { ($0.id, $0.observed) })
        return current.keys.sorted() == previous.keys.sorted() && current.allSatisfy { key, item in
            guard let original = previous[key] else { return false }
            return Self.sameOwner(item, original)
        }
    }

    static func sameOwner(_ item: MenuBarObservedItem, _ other: MenuBarObservedItem) -> Bool {
        guard item.bundleIdentifier == other.bundleIdentifier else { return false }
        // 输入法菜单是系统设置目标，显示/隐藏可以撤除并重建其代理，不把正常恢复当成应用换人。
        if item.bundleIdentifier == MenuBarInputMenu.bundleIdentifier { return true }
        return item.processID == other.processID && item.processLaunchDate == other.processLaunchDate
    }

    func applying(_ moves: [MenuBarArrangementMove]) throws -> (layout: MenuBarArrangementLayout, patch: [String: Double], collectedApplications: Set<String>) {
        var updated = positions
        var selected = collectedApplications
        var changed = Set<String>()
        func layout() -> MenuBarArrangementLayout {
            let ordered = items.filter(\.isEditable).sorted { updated[$0.id]! > updated[$1.id]! }
            return .init(collected: ordered.filter { selected.contains($0.observed.bundleIdentifier!) }.map(\.id),
                resident: ordered.filter { !selected.contains($0.observed.bundleIdentifier!) }.map(\.id))
        }
        for move in moves {
            guard let item = items.first(where: { $0.id == move.itemID && $0.isEditable }),
                  let bundle = item.observed.bundleIdentifier, move.beforeID != move.itemID else { throw MenuBarArrangementError.changed }
            if move.zone == .collected { selected.insert(bundle) } else { selected.remove(bundle) }
            guard move.reorders else { continue } // 行内切换只改收纳名单，保留用户在系统中排好的顺序。
            let row = layout()[move.zone].filter { $0 != move.itemID }
            let others = updated.filter { $0.key != move.itemID }.values.filter { $0.isFinite && $0 >= 0 }
            let left: Double?, right: Double
            if let before = move.beforeID {
                guard row.contains(before), let value = updated[before] else { throw MenuBarArrangementError.changed }
                right = value; left = others.filter { $0 > value }.min()
            } else if let last = row.last, let value = updated[last] {
                left = value; right = others.filter { $0 < value }.max() ?? 0
            } else { continue }
            let value = left.map { ($0 + right) / 2 } ?? right + 40
            guard value.isFinite, value > right, left.map({ value < $0 }) ?? true else { throw MenuBarArrangementError.invalidOrder }
            updated[move.itemID] = value; changed.insert(move.itemID)
        }
        return (layout(), updated.filter { changed.contains($0.key) && positions[$0.key] != $0.value }, selected)
    }
}
