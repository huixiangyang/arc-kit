import ArcKitPersistence
import Foundation

/// 和应用共用 SQLite 写连接。图片随记录进入完整备份，不同步数据库文件本身。
final class ClipboardStore: @unchecked Sendable {
    let database: ArcKitDatabase
    init(database: ArcKitDatabase) { self.database = database }

    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE clipboard_items (
                id TEXT PRIMARY KEY, account_id TEXT, value BLOB NOT NULL,
                kind TEXT NOT NULL, preview TEXT NOT NULL, search_text TEXT NOT NULL,
                source_name TEXT NOT NULL, source_bundle TEXT NOT NULL, device_name TEXT NOT NULL,
                created_at REAL NOT NULL, favorite INTEGER NOT NULL, deleted INTEGER NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1, system_fields BLOB
            );
            CREATE INDEX clipboard_items_history ON clipboard_items(account_id, hidden, deleted, created_at DESC);
            CREATE TABLE clipboard_sync_state (id INTEGER PRIMARY KEY CHECK(id=1), account_id TEXT, token BLOB, approved INTEGER NOT NULL DEFAULT 0);
            INSERT INTO clipboard_sync_state(id) VALUES(1);
            """)
    }

    struct SyncState: Sendable { let account: String?; let token: Data?; let approved: Bool }
    func state() throws -> SyncState {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_sync_state WHERE id=1") else { throw ClipboardError.invalidSettings }
            return SyncState(account: row["account_id"], token: row["token"], approved: row["approved"])
        }
    }

    /// 账户变更先撤销上传许可；旧账户的记录留在原分区，不复制到新账户。
    func revokeApproval() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE clipboard_sync_state SET approved=0 WHERE id=1 AND approved<>0")
            if db.changesCount > 0 { try ArcKitDatabase.advance(db) }
        }
    }

    func approve(account: String) throws {
        try database.write { db in
            let previous = try String.fetchOne(db, sql: "SELECT account_id FROM clipboard_sync_state WHERE id=1")
            try db.execute(sql: "UPDATE clipboard_sync_state SET account_id=?, approved=1, token=CASE WHEN account_id=? THEN token ELSE NULL END WHERE id=1", arguments: [account, account])
            // 用户首次明确连接时纳入本地历史；换账户时只连接，不能搬运旧账户数据。
            if previous == nil {
                try db.execute(sql: "UPDATE clipboard_items SET account_id=? WHERE account_id IS NULL", arguments: [account])
            }
            try ArcKitDatabase.advance(db)
        }
    }

    func list(account: String?, search: String = "", favorites: Bool = false, source: String? = nil) throws -> [ClipboardSummary] {
        try database.read { db in
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,kind,preview,source_name,source_bundle,device_name,created_at,favorite,dirty
                FROM clipboard_items WHERE (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0
                AND (?=0 OR favorite=1) AND (? IS NULL OR source_bundle=?)
                AND (?='' OR instr(lower(search_text),lower(?))>0 OR instr(lower(source_name),lower(?))>0)
                ORDER BY favorite DESC,created_at DESC
                """, arguments: [account, favorites, source, source, query, query, query])
            return try rows.map { row in
                guard let kind = ClipboardContentKind(rawValue: row["kind"]) else { throw ClipboardError.invalidContent }
                return ClipboardSummary(id: row["id"], kind: kind, preview: row["preview"], sourceName: row["source_name"],
                    sourceBundleID: row["source_bundle"], deviceName: row["device_name"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]), favorite: row["favorite"], pending: row["dirty"])
            }
        }
    }

    func sources(account: String?) throws -> [ClipboardSource] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT source_bundle, MAX(source_name) AS name FROM clipboard_items WHERE (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0 GROUP BY source_bundle ORDER BY name", arguments: [account])
                .map { ClipboardSource(id: $0["source_bundle"], name: $0["name"]) }
        }
    }

    func item(id: String, account: String?) throws -> ClipboardItem? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM clipboard_items WHERE id=? AND (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0", arguments: [id, account]) else { return nil }
            return try JSONDecoder().decode(ClipboardItem.self, from: data)
        }
    }

    func insert(_ item: ClipboardItem, account: String?) throws {
        try item.validate()
        try database.write { db in
            // 只消除同设备连续重复；复制同一段文字的不同设备仍保留来源，不做内容摘要扫描。
            if let previous = try Data.fetchOne(db, sql: "SELECT value FROM clipboard_items WHERE account_id IS ? AND hidden=0 AND deleted=0 ORDER BY created_at DESC LIMIT 1", arguments: [account]),
               let last = try? JSONDecoder().decode(ClipboardItem.self, from: previous),
               last.content == item.content, last.deviceName == item.deviceName { return }
            try Self.save(item, account: account, db: db)
        }
    }

    func setFavorite(id: String, account: String?, value: Bool) throws {
        try mutate(id: id, account: account) { $0.favorite = value; $0.touch() }
    }

    func deleteEverywhere(id: String, account: String?) throws {
        try mutate(id: id, account: account) { $0.erase() }
    }

    private func mutate(id: String, account: String?, update: (inout ClipboardItem) -> Void) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE id=? AND (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0", arguments: [id, account]) else { return }
            var item = try JSONDecoder().decode(ClipboardItem.self, from: row["value"])
            update(&item)
            try Self.save(item, account: row["account_id"], systemFields: row["system_fields"], db: db)
        }
    }

    /// 本机清理保留轻量身份，云端重拉不会把同一条记录重新显示出来。
    func clearLocal(account: String?) throws {
        try database.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM clipboard_items WHERE (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0", arguments: [account])
            for id in ids {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE id=?", arguments: [id]) else { continue }
                var item = try JSONDecoder().decode(ClipboardItem.self, from: row["value"])
                item.content = nil; item.sourceName = ""; item.sourceBundleID = ""; item.deviceName = ""
                try Self.save(item, account: row["account_id"], hidden: true, dirty: false, systemFields: row["system_fields"], db: db)
            }
        }
    }

    func prune(account: String?, days: Int, now: Date = Date()) throws {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,created_at FROM clipboard_items WHERE (account_id IS NULL OR account_id=?) AND hidden=0 AND deleted=0 AND favorite=0
                ORDER BY created_at DESC
                """, arguments: [account])
            for (index, row) in rows.enumerated() where index >= 1000 || (row["created_at"] as Double) < now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 {
                // 先筛元数据，再逐条释放正文，避免一次载入整段图片历史。
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE id=?", arguments: [row["id"] as String]) else { continue }
                var item = try JSONDecoder().decode(ClipboardItem.self, from: row["value"])
                item.erase()
                try Self.save(item, account: row["account_id"], systemFields: row["system_fields"], db: db)
            }
        }
    }

    func pending(account: String, scope: ClipboardSyncScope) throws -> [ClipboardUpload] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT value,system_fields FROM clipboard_items WHERE account_id=? AND dirty=1 AND hidden=0
                AND (deleted=1 OR ?='history' OR favorite=1 OR system_fields IS NOT NULL)
                ORDER BY deleted DESC,created_at LIMIT 10
                """, arguments: [account, scope.rawValue]).map { row in
                ClipboardUpload(item: try JSONDecoder().decode(ClipboardItem.self, from: row["value"]), systemFields: row["system_fields"])
            }
        }
    }

    /// 远端变更和令牌在同一事务中提交，失败后重拉，不跳过尚未落盘的内容。
    func merge(_ changes: [ClipboardRemoteChange], removed: [String] = [], token: Data?, account: String, advanceToken: Bool = true) throws {
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT account_id FROM clipboard_sync_state WHERE id=1 AND approved=1") == account else { throw ClipboardError.accountChanged }
            for change in changes {
                try change.item.validate()
                let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE id=?", arguments: [change.item.id])
                if let row {
                    guard (row["account_id"] as String?) == account else { throw ClipboardError.invalidCloudRecord }
                    let local = try JSONDecoder().decode(ClipboardItem.self, from: row["value"])
                    let hidden: Bool = row["hidden"]
                    let localWins = local.supersedes(change.item)
                    var winner = localWins ? local : change.item
                    if hidden { winner.content = nil; winner.sourceName = ""; winner.sourceBundleID = ""; winner.deviceName = "" }
                    try Self.save(winner, account: account, hidden: hidden, dirty: localWins && !hidden,
                        systemFields: change.systemFields, db: db)
                } else {
                    try Self.save(change.item, account: account, dirty: false, systemFields: change.systemFields, db: db)
                }
            }
            for id in removed {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM clipboard_items WHERE id=? AND account_id=?", arguments: [id, account]) else { continue }
                var item = try JSONDecoder().decode(ClipboardItem.self, from: row["value"])
                item.erase()
                try Self.save(item, account: account, dirty: false, db: db)
            }
            if advanceToken { try db.execute(sql: "UPDATE clipboard_sync_state SET token=? WHERE id=1", arguments: [token]) }
            if advanceToken { try ArcKitDatabase.advance(db) }
        }
    }

    private static func save(_ item: ClipboardItem, account: String?, hidden: Bool = false, dirty: Bool = true, systemFields: Data? = nil, db: Database) throws {
        let text = item.content?.text ?? ""
        try db.execute(sql: """
            INSERT INTO clipboard_items(id,account_id,value,kind,preview,search_text,source_name,source_bundle,device_name,created_at,favorite,deleted,hidden,dirty,system_fields)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            account_id=excluded.account_id,value=excluded.value,kind=excluded.kind,preview=excluded.preview,search_text=excluded.search_text,
            source_name=excluded.source_name,source_bundle=excluded.source_bundle,device_name=excluded.device_name,
            created_at=excluded.created_at,favorite=excluded.favorite,deleted=excluded.deleted,hidden=excluded.hidden,dirty=excluded.dirty,system_fields=excluded.system_fields
            """, arguments: [item.id, account, try JSONEncoder().encode(item), item.content?.kind.rawValue ?? "text",
                text.prefix(240).split(whereSeparator: \.isWhitespace).joined(separator: " "), text, item.sourceName, item.sourceBundleID, item.deviceName,
                item.createdAt.timeIntervalSince1970, item.favorite, item.deleted, hidden, dirty, systemFields])
        try ArcKitDatabase.advance(db)
    }
}
