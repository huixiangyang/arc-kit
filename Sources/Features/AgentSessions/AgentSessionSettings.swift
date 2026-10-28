import ArcKitPlatform
import Foundation

public struct AgentSessionSource: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var attachmentRoots: [String]

    public init(id: UUID = UUID(), name: String, path: String, attachmentRoots: [String] = []) {
        self.id = id; self.name = name; self.path = path; self.attachmentRoots = attachmentRoots
    }
}

/// 来源只有用户明确添加后才扫描；自动保护随已提交配置生效。
public struct AgentSessionSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool = false
    public var retentionDays: Int = 30
    public var capacityGB: Int = 5
    public var sources: [AgentSessionSource] = []
    public static let defaults = AgentSessionSettings()

    public init() {}
    private enum CodingKeys: String, CodingKey { case isEnabled, retentionDays, capacityGB, sources }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        retentionDays = try c.decode(Int.self, forKey: .retentionDays)
        capacityGB = try c.decode(Int.self, forKey: .capacityGB)
        sources = try c.decode([AgentSessionSource].self, forKey: .sources)
        guard (1...3650).contains(retentionDays), (1...1000).contains(capacityGB), sources.count <= 32,
              Set(sources.map(\.id)).count == sources.count, Set(sources.map(\.path)).count == sources.count,
              sources.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 120 && Self.validPath($0.path) && $0.attachmentRoots.count <= 16 && $0.attachmentRoots.allSatisfy(Self.validPath) }) else {
            throw DecodingError.dataCorruptedError(forKey: .sources, in: c, debugDescription: L10n.string(.AgentSessions.errorSettings))
        }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\0") && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
    static let recordLayout = ArcKitRecordLayout("agent_session_preferences", fields: ["isEnabled", "retentionDays", "capacityGB"], children: [
        "sources": ArcKitRecordLayout("agent_session_sources", fields: ["id", "name", "path", "attachmentRoots"], json: ["attachmentRoots"])
    ])
}
