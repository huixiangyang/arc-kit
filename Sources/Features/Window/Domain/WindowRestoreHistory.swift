import ArcKitPlatform
import CoreGraphics
import Foundation

/// 窗口编号存在时使用稳定编号；没有编号时才使用标题与 AX 角色组合。
public struct WindowRestoreIdentity: Hashable, Sendable {
    public var pid: Int32
    public var windowNumber: Int?
    public var title: String
    public var role: String
    public var subrole: String

    public init(pid: Int32, windowNumber: Int?, title: String, role: String, subrole: String) {
        self.pid = pid
        self.windowNumber = windowNumber
        self.title = title
        self.role = role
        self.subrole = subrole
    }

    public var diagnosticDescription: String {
        if let windowNumber {
            return "pid=\(pid) windowNumber=\(windowNumber)"
        }
        return "pid=\(pid) title=\(title) role=\(role) subrole=\(subrole)"
    }

    public static func == (lhs: WindowRestoreIdentity, rhs: WindowRestoreIdentity) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        if let lhsWindowNumber = lhs.windowNumber,
           let rhsWindowNumber = rhs.windowNumber {
            return lhsWindowNumber == rhsWindowNumber
        }
        return lhs.windowNumber == nil
            && rhs.windowNumber == nil
            && lhs.title == rhs.title
            && lhs.role == rhs.role
            && lhs.subrole == rhs.subrole
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        if let windowNumber {
            hasher.combine("windowNumber")
            hasher.combine(windowNumber)
        } else {
            hasher.combine("fallback")
            hasher.combine(title)
            hasher.combine(role)
            hasher.combine(subrole)
        }
    }
}

public struct WindowRestoreHistory: Equatable, Sendable {
    public private(set) var frames: [WindowRestoreIdentity: CGRect]
    public private(set) var order: [WindowRestoreIdentity]
    public var maximumCount: Int

    public init(maximumCount: Int = 64) {
        frames = [:]
        order = []
        self.maximumCount = maximumCount
    }

    public var count: Int { frames.count }

    public func frame(for identity: WindowRestoreIdentity) -> CGRect? {
        frames[identity]
    }

    public mutating func remember(_ frame: CGRect, for identity: WindowRestoreIdentity) {
        frames[identity] = frame
        order.removeAll { $0 == identity }
        order.append(identity)
        while order.count > maximumCount {
            let removed = order.removeFirst()
            frames.removeValue(forKey: removed)
        }
    }
}
