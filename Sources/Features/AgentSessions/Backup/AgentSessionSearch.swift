import ArcKitPersistence
import Foundation

struct AgentSessionSearchRequest: Equatable, Sendable {
    var text: String
    var sourceID: UUID?
    var project: String
}

struct AgentSessionSearchHit: Identifiable, Sendable {
    let version: AgentSessionVersion
    let entryID: Int
    let kind: String
    let excerpt: String
    var id: String { version.id.uuidString + ":" + String(entryID) }
}

struct AgentSessionSearchResult: Sendable {
    var hits: [AgentSessionSearchHit] = []
    var hasMore = false
}

extension AgentSessionStore {
    /// 派生索引与原始备份共用数据库。按资产去重，父会话检查点不重复存储正文。
    static func createSearchSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE agent_session_search_documents (
                digest TEXT PRIMARY KEY REFERENCES assets(digest) ON DELETE CASCADE
            );
            CREATE TABLE agent_session_search_entries (
                id INTEGER PRIMARY KEY,
                digest TEXT NOT NULL REFERENCES agent_session_search_documents(digest) ON DELETE CASCADE,
                entry_id INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL, normalized TEXT NOT NULL,
                UNIQUE(digest,entry_id)
            );
            CREATE VIRTUAL TABLE agent_session_search_fts USING fts5(
                normalized, content='agent_session_search_entries', content_rowid='id', tokenize='trigram'
            );
            CREATE TRIGGER agent_session_search_insert AFTER INSERT ON agent_session_search_entries BEGIN
                INSERT INTO agent_session_search_fts(rowid,normalized) VALUES(new.id,new.normalized);
            END;
            CREATE TRIGGER agent_session_search_delete AFTER DELETE ON agent_session_search_entries BEGIN
                INSERT INTO agent_session_search_fts(agent_session_search_fts,rowid,normalized) VALUES('delete',old.id,old.normalized);
            END;
            """)
    }

    static func indexSearch(_ payload: AgentSessionPayload, digest: String, db: Database) throws {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM agent_session_search_documents WHERE digest=?)", arguments: [digest]) == true { return }
        try db.execute(sql: "INSERT INTO agent_session_search_documents(digest) VALUES (?)", arguments: [digest])
        // 只索引用户和助手正文；工具输出、系统上下文与附件不进入消息搜索。
        for entry in try CodexSessionAdapter.transcript(payload.rollout) where entry.kind == "user" || entry.kind == "assistant" {
            try Task.checkCancellation()
            try db.execute(sql: "INSERT INTO agent_session_search_entries(digest,entry_id,kind,text,normalized) VALUES (?,?,?,?,?)",
                           arguments: [digest, entry.id, entry.kind, entry.text, searchable(entry.text)])
        }
    }

    /// 旧库只在第一次正文搜索时补索引，逐资产提交；取消后已完成的部分仍可复用。
    func prepareSearchIndex() throws {
        var seen = Set<String>()
        for version in try versions() {
            try Task.checkCancellation()
            let digest = URL(fileURLWithPath: version.relativePath).deletingPathExtension().lastPathComponent
            guard seen.insert(digest).inserted else { continue }
            let indexed = try database.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM agent_session_search_documents WHERE digest=?)", arguments: [digest]) == true }
            guard !indexed else { continue }
            let saved = try payload(version)
            try Task.checkCancellation()
            try database.write { try Self.indexSearch(saved, digest: digest, db: $0) }
        }
    }

    /// 每个会话返回最新的匹配版本和其中最早的匹配消息，避免重复版本占满结果。
    func search(_ request: AgentSessionSearchRequest, limit: Int = 80) throws -> AgentSessionSearchResult {
        let query = Self.searchable(request.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return .init() }
        try Task.checkCancellation()
        return try database.read { db in
            // Trigram 不支持不足三个 Unicode 字符的查询，短中文直接查派生正文，不扫描原始文件。
            let usesFTS = query.unicodeScalars.count >= 3
            let join = usesFTS ? "JOIN agent_session_search_fts ON agent_session_search_fts.rowid=e.id" : ""
            let matching = usesFTS ? "agent_session_search_fts MATCH ? AND " : ""
            var arguments: StatementArguments = []
            if usesFTS { arguments += ["\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""] }
            arguments += [query, request.sourceID?.uuidString, request.sourceID?.uuidString, request.project, request.project, max(1, limit) + 1]
            let rows = try Row.fetchAll(db, sql: """
                WITH matches AS (
                    SELECT v.*,a.path,a.byte_count,e.entry_id,e.kind,e.text,
                        row_number() OVER(PARTITION BY v.source_id,v.session_id ORDER BY v.captured_at DESC,v.id,e.entry_id) AS search_rank
                    FROM agent_session_search_entries e
                    \(join)
                    JOIN agent_session_versions v ON v.digest=e.digest
                    JOIN assets a ON a.digest=v.digest
                    WHERE \(matching)instr(e.normalized,?)>0
                        AND (? IS NULL OR v.source_id=?)
                        AND (?='' OR json_extract(v.metadata,'$.project')=?)
                )
                SELECT * FROM matches WHERE search_rank=1 ORDER BY captured_at DESC,id LIMIT ?
                """, arguments: arguments)
            let hits = try rows.prefix(max(1, limit)).map { row -> AgentSessionSearchHit in
                let entryID: Int = row["entry_id"], kind: String = row["kind"], text: String = row["text"]
                return .init(version: try Self.version(row), entryID: entryID, kind: kind, excerpt: Self.excerpt(text, query: request.text))
            }
            return .init(hits: hits, hasMore: rows.count > max(1, limit))
        }
    }

    private static func searchable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func excerpt(_ text: String, query: String) -> String {
        let match = text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive])
        let start = text.index(match?.lowerBound ?? text.startIndex, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match?.upperBound ?? start, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
    }
}
