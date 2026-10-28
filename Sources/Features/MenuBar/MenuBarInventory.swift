import ArcKitPlatform
import CoreGraphics
import Foundation

/// 每次发现都生成新会话。PID、数组顺序和坐标都不能当作跨启动的图标身份。
struct MenuBarInventory: Codable, Sendable {
    enum Access: String, Codable, Sendable { case granted, denied }
    let id: UUID
    let capturedAt: Date
    let systemVersion: String
    let accessibility: Access
    let displays: [MenuBarDisplay]
    let items: [MenuBarObservedItem]
    let issues: [MenuBarInspectionIssue]

    var persistentIdentityCount: Int { items.filter { $0.persistentKey != nil }.count }
    var canUseGeometry: Bool { !displays.isEmpty && !issues.contains { $0.kind == .displayChanged } }
}

struct MenuBarDisplay: Codable, Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    /// 以下统一为 Accessibility 的全局左上原点坐标；一份快照只使用一个坐标基准。
    let frame: CGRect
    let topBand: CGRect
    let notch: CGRect?
    let scale: Double

    static func containing(_ frame: CGRect, in displays: [Self]) -> UInt32? {
        guard frame.isFiniteAndPositive else { return nil }
        let matches = displays.filter { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        return matches.count == 1 ? matches[0].id : nil
    }
}

struct MenuBarObservedItem: Codable, Identifiable, Sendable {
    let id: UUID
    let processID: Int32
    let processLaunchDate: Date?
    let bundleIdentifier: String?
    let applicationName: String
    let accessibilityIdentifier: String?
    let frame: CGRect?
    let displayID: UInt32?
    let declaresPress: Bool
    let declaresShowMenu: Bool
    let positionSettable: Bool
    var label: String? = nil
    var identityEligible = true
    var persistentKey: MenuBarItemKey?
}

extension MenuBarObservedItem {
    var displayTitle: String {
        if bundleIdentifier == "com.apple.MenuBarAgent", let label, !label.isEmpty { return label }
        return applicationName
    }
    var supportsActivation: Bool { (declaresPress || declaresShowMenu) && processLaunchDate != nil }
}

struct MenuBarItemKey: Codable, Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let accessibilityIdentifier: String

    /// 只有命名空间明确、在本次完整发现中唯一的 AX 标识才是持久化候选。
    /// 这是候选身份，不声称已经通过应用重启验收。
    static func assignUniqueCandidates(to items: inout [MenuBarObservedItem]) {
        let keys: [MenuBarItemKey?] = items.map {
            guard $0.identityEligible, let bundle = $0.bundleIdentifier, !bundle.isEmpty,
                  let identifier = $0.accessibilityIdentifier, !identifier.isEmpty else { return nil }
            return .init(bundleIdentifier: bundle, accessibilityIdentifier: identifier)
        }
        let counts = Dictionary(keys.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        for index in items.indices {
            items[index].persistentKey = keys[index].flatMap { counts[$0] == 1 ? $0 : nil }
        }
    }
}

struct MenuBarInspectionIssue: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case permissionDenied, attributeFailed, traversalLimit, displayChanged
    }
    let kind: Kind
    let processID: Int32?
    let attribute: String?
    let errorCode: Int32?
}

extension CGRect {
    var isFiniteAndPositive: Bool {
        [minX, minY, width, height, maxX, maxY].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}
