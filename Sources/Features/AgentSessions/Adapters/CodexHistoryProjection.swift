import ArcKitPersistence
import ArcKitPlatform
import Foundation

/// 分页子会话不能独立 resume。只保存该会话的原生历史投影，恢复时通过 thread/read 验收。
struct CodexHistoryProjection: Codable, Equatable, Sendable {
    enum Value: Codable, Equatable, Sendable {
        case null, integer(Int64), real(Double), text(String)
        init(_ value: DatabaseValue) throws {
            switch value.storage {
            case .null: self = .null
            case let .int64(value): self = .integer(value)
            case let .double(value): self = .real(value)
            case let .string(value): self = .text(value)
            default: throw AgentSessionError.unsupportedFormat
            }
        }
        var databaseValue: DatabaseValue {
            switch self {
            case .null: .null
            case let .integer(value): value.databaseValue
            case let .real(value): value.databaseValue
            case let .text(value): value.databaseValue
            }
        }
    }
    struct Table: Codable, Equatable, Sendable { let name: String; let rows: [[Value]] }
    let tables: [Table]
    // 精确的 0.163.0 历史 schema；SQL 标识符只取此白名单，不能来自备份内容。
    static let contracts: [(String, [String])] = [
        ("thread_turns", ["thread_id", "turn_id", "rollout_ordinal", "status", "error_json", "started_at", "completed_at", "duration_ms", "first_user_item_id", "final_agent_item_id", "rollout_byte_offset", "rollout_end_ordinal", "rollout_end_byte_offset", "root_turn_id"]),
        ("thread_items", ["thread_id", "turn_id", "item_id", "rollout_ordinal", "created_at_ms", "item_json", "item_type", "updated_at_ordinal", "started_at_ms", "completed_at_ms"]),
        ("thread_history_projection_state", ["thread_id", "next_rollout_byte_offset", "next_rollout_ordinal"]),
        ("thread_realtime_items", ["thread_id", "item_id", "rollout_ordinal", "created_at_ms", "item_type", "item_json"])
    ]
    static func capture(root: URL, sessionID: String, byteCount: Int) throws -> Self? {
        let file = try CodexSessionAdapter.safeURL("thread_history_1.sqlite", under: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let snapshot = try CodexSessionAdapter.readDatabase(file) { db in
            try Self(tables: contracts.map { name, columns in
                guard try db.columns(in: name).map(\.name) == columns else { throw AgentSessionError.unsupportedFormat }
                let rows = try Row.fetchAll(db, sql: "SELECT \(columns.joined(separator: ",")) FROM \(name) WHERE thread_id=? ORDER BY rowid", arguments: [sessionID])
                return Table(name: name, rows: try rows.map { row in try columns.map { try Value(row[$0]) } })
            })
        }
        // 投影进度落后或超前都不能冒充当前日志的一致快照。
        guard snapshot.matches(sessionID: sessionID, byteCount: byteCount) else { return nil }
        return snapshot
    }
    func matches(sessionID: String, byteCount: Int) -> Bool {
        guard tables.count == Self.contracts.count, Set(tables.map(\.name)).count == tables.count else { return false }
        for (name, columns) in Self.contracts {
            guard let table = tables.first(where: { $0.name == name }), table.rows.count <= 200_000,
                  table.rows.allSatisfy({ $0.count == columns.count && $0[0] == .text(sessionID) }) else { return false }
        }
        guard let state = tables.first(where: { $0.name == "thread_history_projection_state" }), state.rows.count == 1,
              state.rows[0][1] == .integer(Int64(byteCount)) else { return false }
        return true
    }
    func remapped(original: Data, restored: Data, projects: [String: String], attachments: [String: String]) throws -> Self {
        if original == restored { return self }
        let before = original.split(separator: 10, omittingEmptySubsequences: false)
        let after = restored.split(separator: 10, omittingEmptySubsequences: false)
        guard before.count == after.count else { throw AgentSessionError.invalidArchive }
        var offsets: [Int64: Int64] = [0: 0]; var old: Int64 = 0; var new: Int64 = 0
        for (lhs, rhs) in zip(before.dropLast(), after.dropLast()) {
            old += Int64(lhs.count + 1); new += Int64(rhs.count + 1); offsets[old] = new
        }
        let mapped = try Self(tables: tables.map { table in
            guard let columns = Self.contracts.first(where: { $0.0 == table.name })?.1 else { throw AgentSessionError.invalidArchive }
            return try Table(name: table.name, rows: table.rows.map { row in
                var row = row
                for (index, column) in columns.enumerated() {
                    if column.hasSuffix("byte_offset"), case let .integer(value) = row[index] {
                        guard let mapped = offsets[value] else { throw AgentSessionError.invalidArchive }
                        row[index] = .integer(mapped)
                    }
                    if column == "item_json", case let .text(value) = row[index] {
                        let json = try CodexSessionRestore.remap(Data((value + "\n").utf8), projects: projects, attachments: attachments)
                        row[index] = .text(String(decoding: json.dropLast(), as: UTF8.self))
                    }
                }
                return row
            })
        })
        return mapped
    }
    func install(at root: URL, sessionID: String, byteCount: Int) throws {
        guard matches(sessionID: sessionID, byteCount: byteCount) else { throw AgentSessionError.invalidArchive }
        let file = root.appendingPathComponent("thread_history_1.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { throw AgentSessionError.unsupportedFormat }
        let queue = try DatabaseQueue(path: file.path); defer { try? queue.close() }
        try queue.write { db in
            for (name, columns) in Self.contracts {
                guard try db.columns(in: name).map(\.name) == columns, let table = tables.first(where: { $0.name == name }) else { throw AgentSessionError.unsupportedFormat }
                try db.execute(sql: "DELETE FROM \(name) WHERE thread_id=?", arguments: [sessionID])
                let sql = "INSERT INTO \(name) (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))"
                for row in table.rows { try db.execute(sql: sql, arguments: StatementArguments(row.map(\.databaseValue))) }
            }
        }
    }
}
