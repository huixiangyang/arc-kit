import ArcKitPlatform
import CoreGraphics
import Foundation

/// 场景只保存窗口身份规则与布局；不会保存网页、文档内容或 AX 对象。
public struct WindowScene: Codable, Equatable, Identifiable, Sendable {
    public static let maximumSceneCount = 64
    public static let maximumEntryCount = 24
    public var id: UUID
    public var name: String
    public var displays: [WindowSceneDisplay]
    public var entries: [WindowSceneEntry]
    public var focusEntryID: UUID?
    public var shortcut: WindowSceneShortcut?

    public init(id: UUID = UUID(), name: String, displays: [WindowSceneDisplay], entries: [WindowSceneEntry],
                focusEntryID: UUID? = nil, shortcut: WindowSceneShortcut? = nil) {
        self.id = id
        self.name = name
        self.displays = displays
        self.entries = entries
        self.focusEntryID = focusEntryID
        self.shortcut = shortcut
    }

    public func validate() throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines), name.count <= 80 else {
            throw WindowSceneValidationError.invalidName
        }
        guard !displays.isEmpty, !entries.isEmpty else { throw WindowSceneValidationError.emptyScene }
        guard entries.count <= Self.maximumEntryCount, displays.count <= Self.maximumEntryCount else {
            throw WindowSceneValidationError.tooManyEntries
        }
        guard Set(displays.map(\.id)).count == displays.count,
              Set(entries.map(\.id)).count == entries.count else { throw WindowSceneValidationError.duplicateIdentity }
        for display in displays { try display.validate() }
        let displayIDs = Set(displays.map(\.id))
        for entry in entries {
            try entry.validate()
            guard displayIDs.contains(entry.displayID) else { throw WindowSceneValidationError.invalidDisplay }
        }
        if let focusEntryID, !entries.contains(where: { $0.id == focusEntryID }) {
            throw WindowSceneValidationError.invalidFocus
        }
        if let shortcut { try shortcut.validate() }
    }

    enum CodingKeys: String, CodingKey { case id, name, displays, entries, focusEntryID, shortcut }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        displays = try values.decode([WindowSceneDisplay].self, forKey: .displays)
        entries = try values.decode([WindowSceneEntry].self, forKey: .entries)
        focusEntryID = try values.decodeIfPresent(UUID.self, forKey: .focusEntryID)
        shortcut = try values.decodeIfPresent(WindowSceneShortcut.self, forKey: .shortcut)
        try validate()
    }
}

public struct WindowSceneDisplay: Codable, Equatable, Identifiable, Sendable {
    /// 来自 CGDisplayCreateUUIDFromDisplayID，不依赖 NSScreen 的枚举顺序。
    public var id: String
    public var name: String
    /// 所有场景几何均使用 AX 全局坐标，包含菜单栏与 Dock 扣除后的可用区域。
    public var visibleFrame: CGRect

    public init(id: String, name: String, visibleFrame: CGRect) {
        self.id = id
        self.name = name
        self.visibleFrame = visibleFrame
    }

    public func validate() throws {
        guard !id.isEmpty, !name.isEmpty,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              WindowSceneNormalizedFrame.isFinitePositive(visibleFrame) else { throw WindowSceneValidationError.invalidDisplay }
    }
}

public enum WindowSceneTitleMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case exact
    case contains
    case application
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .exact: L10n.string(.Window.sceneMatchExact)
        case .contains: L10n.string(.Window.sceneMatchContains)
        case .application: L10n.string(.Window.sceneMatchApplication)
        }
    }
}

/// 仅同一次 Host 运行可用；窗口令牌由 Host 持有的 AX 引用签发，不能跨重启猜测复用。
public struct WindowSceneSessionHint: Codable, Equatable, Sendable {
    public var hostLaunchID: UUID
    public var capturedWindowID: UUID
    public var processIdentifier: Int32
    public var applicationLaunchDate: Date?
    public var windowNumber: Int?

    public init(hostLaunchID: UUID, capturedWindowID: UUID, processIdentifier: Int32,
                applicationLaunchDate: Date? = nil, windowNumber: Int? = nil) {
        self.hostLaunchID = hostLaunchID
        self.capturedWindowID = capturedWindowID
        self.processIdentifier = processIdentifier
        self.applicationLaunchDate = applicationLaunchDate
        self.windowNumber = windowNumber
    }
}

public struct WindowSceneEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var applicationName: String
    public var savedTitle: String
    public var titleMatchMode: WindowSceneTitleMatchMode
    public var titleMatchValue: String
    public var displayID: String
    public var normalizedFrame: WindowSceneNormalizedFrame
    public var sessionHint: WindowSceneSessionHint?

    public init(id: UUID = UUID(), bundleIdentifier: String, applicationName: String, savedTitle: String,
                titleMatchMode: WindowSceneTitleMatchMode, titleMatchValue: String, displayID: String,
                normalizedFrame: WindowSceneNormalizedFrame, sessionHint: WindowSceneSessionHint? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.savedTitle = savedTitle
        self.titleMatchMode = titleMatchMode
        self.titleMatchValue = titleMatchValue
        self.displayID = displayID
        self.normalizedFrame = normalizedFrame
        self.sessionHint = sessionHint
    }

    public static func capture(candidate: WindowSceneCandidate, display: WindowSceneDisplay) throws -> Self {
        guard candidate.displayID == display.id else { throw WindowSceneValidationError.invalidDisplay }
        let entry = Self(bundleIdentifier: candidate.bundleIdentifier, applicationName: candidate.applicationName,
                         savedTitle: candidate.title, titleMatchMode: candidate.title.isEmpty ? .application : .exact,
                         titleMatchValue: candidate.title, displayID: display.id,
                         normalizedFrame: try .capture(frame: candidate.frame, visibleFrame: display.visibleFrame),
                         sessionHint: candidate.sessionHint)
        try entry.validate()
        return entry
    }

    public func validate() throws {
        guard !bundleIdentifier.isEmpty, !applicationName.isEmpty, !displayID.isEmpty,
              bundleIdentifier != ArcKitConstants.appBundleIdentifier,
              bundleIdentifier != ArcKitConstants.runtimeHostBundleIdentifier,
              bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw WindowSceneValidationError.invalidEntry
        }
        switch titleMatchMode {
        case .application:
            guard titleMatchValue.isEmpty else { throw WindowSceneValidationError.invalidEntry }
        case .exact, .contains:
            guard !titleMatchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WindowSceneValidationError.invalidEntry
            }
        }
        try normalizedFrame.validate()
        if let hint = sessionHint {
            guard hint.processIdentifier > 0, hint.windowNumber.map({ $0 > 0 }) ?? true,
                  hint.applicationLaunchDate.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
                throw WindowSceneValidationError.invalidEntry
            }
        }
    }
}

public struct WindowSceneNormalizedFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func capture(frame: CGRect, visibleFrame: CGRect) throws -> Self {
        guard isFinitePositive(frame), isFinitePositive(visibleFrame) else { throw WindowSceneValidationError.invalidGeometry }
        let value = Self(x: (frame.minX - visibleFrame.minX) / visibleFrame.width,
                         y: (frame.minY - visibleFrame.minY) / visibleFrame.height,
                         width: frame.width / visibleFrame.width, height: frame.height / visibleFrame.height)
        try value.validate()
        return value
    }

    public func resolve(in visibleFrame: CGRect) throws -> CGRect {
        try validate()
        guard Self.isFinitePositive(visibleFrame) else { throw WindowSceneValidationError.invalidGeometry }
        let frame = CGRect(x: visibleFrame.minX + x * visibleFrame.width,
                           y: visibleFrame.minY + y * visibleFrame.height,
                           width: width * visibleFrame.width, height: height * visibleFrame.height)
        guard Self.isFinitePositive(frame) else { throw WindowSceneValidationError.invalidGeometry }
        return frame
    }

    public func validate() throws {
        // 允许窗口部分越过可用区域，保存时不偷偷裁切；完全离屏或非有限几何直接拒绝。
        guard [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite), width > 0, height > 0,
              width <= 4, height <= 4,
              x < 1, y < 1, x + width > 0, y + height > 0 else { throw WindowSceneValidationError.invalidGeometry }
    }

    public static func isFinitePositive(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }
}

public struct WindowSceneShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var keyEquivalent: String
    public var modifiers: WindowHotKeyModifier
    public var isEnabled: Bool

    public init(keyCode: UInt16, keyEquivalent: String, modifiers: WindowHotKeyModifier = [.control, .option], isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    public var displayShortcut: String { "\(modifiers.displayName)\(keyEquivalent)" }
    public var shortcutIdentifier: String { "\(modifiers.rawValue):\(keyCode)" }
    public var isSafeGlobalShortcut: Bool {
        isEnabled && WindowHotKeyBinding.isValidKeyCode(keyCode)
            && WindowHotKeyBinding.isValidKeyEquivalent(keyEquivalent) && modifiers.containsPrimaryModifier
    }

    public func validate() throws {
        guard WindowHotKeyBinding.isValidKeyCode(keyCode), WindowHotKeyBinding.isValidKeyEquivalent(keyEquivalent),
              modifiers.containsPrimaryModifier, modifiers.rawValue >= 0, modifiers.rawValue & ~15 == 0 else {
            throw WindowSceneValidationError.invalidShortcut
        }
    }
}

public enum WindowSceneValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidName, emptyScene, duplicateIdentity, invalidDisplay, invalidEntry, invalidGeometry, invalidFocus, invalidShortcut
    case tooManyEntries, tooManyScenes

    public var errorDescription: String? {
        switch self {
        case .invalidName: L10n.string(.Window.sceneValidationName)
        case .emptyScene: L10n.string(.Window.sceneValidationEmpty)
        case .duplicateIdentity: L10n.string(.Window.sceneValidationIdentity)
        case .invalidDisplay: L10n.string(.Window.sceneValidationDisplay)
        case .invalidEntry: L10n.string(.Window.sceneValidationEntry)
        case .invalidGeometry: L10n.string(.Window.sceneValidationGeometry)
        case .invalidFocus: L10n.string(.Window.sceneValidationFocus)
        case .invalidShortcut: L10n.string(.Window.sceneValidationShortcut)
        case .tooManyEntries: L10n.string(.Window.sceneValidationEntryLimit)
        case .tooManyScenes: L10n.string(.Window.sceneValidationSceneLimit)
        }
    }
}
