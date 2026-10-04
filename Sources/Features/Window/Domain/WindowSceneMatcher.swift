import CoreGraphics
import Foundation

public struct WindowSceneCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var applicationName: String
    public var title: String
    public var displayID: String
    public var frame: CGRect
    public var sessionHint: WindowSceneSessionHint?

    public init(id: UUID = UUID(), bundleIdentifier: String, applicationName: String, title: String,
                displayID: String, frame: CGRect, sessionHint: WindowSceneSessionHint? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.displayID = displayID
        self.frame = frame
        self.sessionHint = sessionHint
    }
}

public struct WindowSceneInventory: Codable, Equatable, Sendable {
    public var hostLaunchID: UUID
    public var displays: [WindowSceneDisplay]
    public var candidates: [WindowSceneCandidate]
    public var capturedAt: Date

    public init(hostLaunchID: UUID, displays: [WindowSceneDisplay], candidates: [WindowSceneCandidate], capturedAt: Date = Date()) {
        self.hostLaunchID = hostLaunchID
        self.displays = displays
        self.candidates = candidates
        self.capturedAt = capturedAt
    }
}

public enum WindowScenePlanStatus: String, Codable, Equatable, Sendable {
    case ready, missingWindow, ambiguousWindow, missingDisplay, conflictingAssignment
}

public struct WindowScenePlannedEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { entryID }
    public var entryID: UUID
    public var candidateID: UUID?
    public var targetFrame: CGRect?
    public var status: WindowScenePlanStatus
    public var candidateIDs: [UUID]

    public init(entryID: UUID, candidateID: UUID? = nil, targetFrame: CGRect? = nil,
                status: WindowScenePlanStatus, candidateIDs: [UUID] = []) {
        self.entryID = entryID
        self.candidateID = candidateID
        self.targetFrame = targetFrame
        self.status = status
        self.candidateIDs = candidateIDs
    }
}

public enum WindowSceneMatcher {
    public static func plan(scene: WindowScene, inventory: WindowSceneInventory) throws -> [WindowScenePlannedEntry] {
        try scene.validate()
        guard Set(inventory.displays.map(\.id)).count == inventory.displays.count,
              Set(inventory.candidates.map(\.id)).count == inventory.candidates.count else {
            throw WindowSceneValidationError.duplicateIdentity
        }
        for display in inventory.displays { try display.validate() }
        let displays = Dictionary(uniqueKeysWithValues: inventory.displays.map { ($0.id, $0) })
        var planned: [WindowScenePlannedEntry] = try scene.entries.map { entry in
            // 缺屏必须独立报告，不能按当前主屏、屏幕名称或列表位置替补。
            guard let display = displays[entry.displayID] else {
                return WindowScenePlannedEntry(entryID: entry.id, status: .missingDisplay)
            }
            let applicationWindows = inventory.candidates.filter { $0.bundleIdentifier == entry.bundleIdentifier }
            let sameSession: [WindowSceneCandidate]
            if let hint = entry.sessionHint, hint.hostLaunchID == inventory.hostLaunchID {
                sameSession = applicationWindows.filter { candidate in
                    candidate.id == hint.capturedWindowID && candidate.sessionHint == hint
                }
                // 原应用实例仍存在时，消失的捕获引用不能被同标题的新窗口顶替。
                // 只有 PID 或可核验的应用启动时间改变，才能按跨启动规则重新匹配。
                if sameSession.isEmpty, applicationWindows.contains(where: { candidate in
                    guard let current = candidate.sessionHint else { return true }
                    guard current.processIdentifier == hint.processIdentifier else { return false }
                    if let previousLaunch = hint.applicationLaunchDate, let currentLaunch = current.applicationLaunchDate {
                        return previousLaunch == currentLaunch
                    }
                    return true
                }) {
                    return WindowScenePlannedEntry(entryID: entry.id, status: .missingWindow)
                }
            } else { sameSession = [] }
            let matches = sameSession.isEmpty ? applicationWindows.filter { matchesTitle(entry, candidate: $0) } : sameSession
            guard matches.count == 1, let candidate = matches.first else {
                return WindowScenePlannedEntry(entryID: entry.id, status: matches.isEmpty ? .missingWindow : .ambiguousWindow,
                                               candidateIDs: matches.map(\.id))
            }
            return WindowScenePlannedEntry(entryID: entry.id, candidateID: candidate.id,
                                           targetFrame: try entry.normalizedFrame.resolve(in: display.visibleFrame),
                                           status: .ready, candidateIDs: [candidate.id])
        }
        // 先独立匹配整组，再拒绝所有竞争同一窗口的条目；不靠列表顺序偷偷决定赢家。
        let assignments = Dictionary(grouping: planned.compactMap(\.candidateID), by: { $0 })
        for index in planned.indices {
            guard let candidateID = planned[index].candidateID, (assignments[candidateID]?.count ?? 0) > 1 else { continue }
            planned[index].status = .conflictingAssignment
            planned[index].candidateID = nil
            planned[index].targetFrame = nil
        }
        return planned
    }

    private static func matchesTitle(_ entry: WindowSceneEntry, candidate: WindowSceneCandidate) -> Bool {
        switch entry.titleMatchMode {
        case .exact: candidate.title == entry.titleMatchValue
        case .contains: candidate.title.range(of: entry.titleMatchValue, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .application: true
        }
    }
}
