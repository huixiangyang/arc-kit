import ArcKitPlatform
import Foundation

/// HIToolbox 的记录原样保留；只精简键盘输入源，不删除字符面板等非键盘服务。
struct InputSourceRecord: Equatable, Identifiable {
    let raw: [String: Any]
    var kind: String { raw["InputSourceKind"] as? String ?? "" }
    var bundleID: String? { raw["Bundle ID"] as? String }
    var modeID: String? { raw["Input Mode"] as? String }
    var isAuxiliary: Bool { kind == "Non Keyboard Input Method" }
    var selectionID: String { kind == "Keyboard Layout" ? id : "input-method|\(bundleID ?? "")" }
    var id: String { [kind, bundleID ?? "", modeID ?? "", String(describing: raw["KeyboardLayout ID"] ?? ""), raw["KeyboardLayout Name"] as? String ?? ""].joined(separator: "|") }
    static func == (lhs: Self, rhs: Self) -> Bool { NSDictionary(dictionary: lhs.raw).isEqual(to: rhs.raw) }

    func matches(_ source: InputSourceDescriptor) -> Bool {
        if kind == "Keyboard Layout", let name = raw["KeyboardLayout Name"] as? String {
            return source.layoutNames.contains(name) && (bundleID == nil || bundleID == source.bundleID)
        }
        guard bundleID == source.bundleID else { return false }
        // InputModeID 与 InputSourceID 不同：搜狗前者为 com.sogou.inputmethod.pinyin。
        if kind == "Input Mode" { return modeID != nil && modeID == source.modeID }
        return kind == "Keyboard Input Method" && source.modeID == nil
    }
}

struct InputSourceDescriptor: Equatable {
    let id: String
    let bundleID: String
    let modeID: String?
    let name: String
    let enabled: Bool
    let selectable: Bool
    var layoutNames: Set<String> = []

    func requiringEnabledParent(in bundles: Set<String>) -> Self {
        // TIS 的子模式标记可在父输入法停用后仍为 true，必须同时核对父项。
        Self(id: id, bundleID: bundleID, modeID: modeID, name: name,
             enabled: enabled && (modeID == nil || bundles.contains(bundleID)), selectable: selectable, layoutNames: layoutNames)
    }
}

struct InputSourceConfiguration: Equatable {
    static let enabledKey = "AppleEnabledInputSources"
    static let selectedKey = "AppleSelectedInputSources"
    static let historyKey = "AppleInputSourceHistory"
    static let keys = [enabledKey, selectedKey, historyKey]
    let values: [String: [InputSourceRecord]]
    var enabled: [InputSourceRecord] { values[Self.enabledKey] ?? [] }
    var keyboards: [InputSourceRecord] { enabled.filter { !$0.isAuxiliary } }
    var propertyList: [String: Any] { values.mapValues { $0.map(\.raw) } }

    init(propertyList: [String: Any]) throws {
        guard Set(propertyList.keys).isSubset(of: Set(Self.keys)), propertyList[Self.enabledKey] != nil else { throw InputSourceToolError.invalidConfiguration }
        var records: [String: [InputSourceRecord]] = [:]
        for (key, value) in propertyList {
            guard let list = value as? [[String: Any]] else { throw InputSourceToolError.invalidConfiguration }
            records[key] = try list.map { raw in
                let record = InputSourceRecord(raw: raw)
                switch record.kind {
                case "Input Mode":
                    guard let bundle = record.bundleID, !bundle.isEmpty, let mode = record.modeID, !mode.isEmpty else { throw InputSourceToolError.invalidConfiguration }
                case "Keyboard Input Method", "Non Keyboard Input Method":
                    guard let bundle = record.bundleID, !bundle.isEmpty else { throw InputSourceToolError.invalidConfiguration }
                case "Keyboard Layout":
                    guard raw["KeyboardLayout ID"] is NSNumber, let name = raw["KeyboardLayout Name"] as? String, !name.isEmpty else { throw InputSourceToolError.invalidConfiguration }
                default: throw InputSourceToolError.invalidConfiguration
                }
                return record
            }
        }
        guard let enabled = records[Self.enabledKey], !enabled.filter({ !$0.isAuxiliary }).isEmpty,
              Set(enabled.map(\.id)).count == enabled.count else { throw InputSourceToolError.invalidConfiguration }
        values = records
    }

    func keeping(_ selection: Set<String>, fallback: InputSourceRecord) throws -> Self {
        guard !selection.isEmpty, selection.isSubset(of: Set(keyboards.map(\.selectionID))),
              keyboards.contains(fallback), selection.contains(fallback.selectionID) else { throw InputSourceToolError.targetUnavailable }
        // 一个复选项代表一个输入法及其全部模式；键盘布局单独选择，不偏好任何品牌。
        var result = values
        for key in Self.keys {
            guard let records = values[key] else { continue }
            var retained = records.filter { $0.isAuxiliary || selection.contains($0.selectionID) }
            // 当前选择被移除时才补入一个仍可用的保留项，不改写仍有效的选择顺序。
            if key != Self.enabledKey && !retained.contains(where: { !$0.isAuxiliary }) { retained.append(fallback) }
            result[key] = retained
        }
        return try Self(propertyList: result.mapValues { $0.map(\.raw) })
    }
}

struct InputSourceRecovery: Codable {
    let version: Int
    let createdAt: Date
    let before: Data
    let after: Data

    init(before: InputSourceConfiguration, after: InputSourceConfiguration) throws {
        version = 2; createdAt = Date()
        self.before = try PropertyListSerialization.data(fromPropertyList: before.propertyList, format: .binary, options: 0)
        self.after = try PropertyListSerialization.data(fromPropertyList: after.propertyList, format: .binary, options: 0)
    }
    func configuration(before: Bool) throws -> InputSourceConfiguration {
        guard version == 2, let value = try PropertyListSerialization.propertyList(from: before ? self.before : after, format: nil) as? [String: Any] else {
            throw InputSourceToolError.invalidRecovery
        }
        return try InputSourceConfiguration(propertyList: value)
    }
}

enum InputSourceToolError: LocalizedError {
    case invalidConfiguration, targetUnavailable, changed, writeFailed, rolledBack, recoveryRequired, invalidRecovery
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: L10n.string(.Tools.errorConfiguration)
        case .targetUnavailable: L10n.string(.Tools.errorTarget)
        case .changed: L10n.string(.Tools.errorChanged)
        case .writeFailed: L10n.string(.Tools.errorWrite)
        case .rolledBack: L10n.string(.Tools.errorRolledBack)
        case .recoveryRequired: L10n.string(.Tools.errorRecoveryRequired)
        case .invalidRecovery: L10n.string(.Tools.errorRecovery)
        }
    }
}
