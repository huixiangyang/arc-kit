import ArcKitPersistence
import ArcKitPlatform
import Foundation

struct AgentRestorePlan: Sendable {
    struct Item: Identifiable, Sendable {
        enum Disposition: String, Sendable { case new, identical, conflict }
        let payload: AgentSessionPayload
        let existingPath: String?
        let disposition: Disposition
        let existingData: Data?
        var id: String { payload.metadata.sessionID }
    }
    let destination: URL
    let items: [Item]
    let projectMappings: [String: String]
    var conflictCount: Int { items.filter { $0.disposition == .conflict }.count }
}

/// 原生恢复先在隔离目录经官方客户端回读，再把选中行合入目标库；不覆盖其他会话。
struct CodexSessionRestore: Sendable {
    let temporaryRoot: URL
    private static let databases: [(String, [(String, String)])] = [
        ("state_5.sqlite", [("threads", "id"), ("thread_dynamic_tools", "thread_id"), ("thread_spawn_edges", "child_thread_id"), ("thread_attachments", "thread_id")]),
        ("thread_history_1.sqlite", [("thread_turns", "thread_id"), ("thread_items", "thread_id"), ("thread_history_projection_state", "thread_id"), ("thread_realtime_items", "thread_id")])
    ]
    private struct Journal: Codable {
        struct Entry: Codable { let path: String; let existed: Bool; let publish: Bool }
        var phase: String
        var applied: Int
        var entries: [Entry]
    }
    func plan(_ payloads: [AgentSessionPayload], destination: URL, projectMappings: [String: String] = [:]) throws -> AgentRestorePlan {
        guard destination.standardizedFileURL.path == destination.path, destination.resolvingSymlinksInPath().path == destination.path,
              !destination.path.hasPrefix(temporaryRoot.path + "/"), destination.path != "/",
              !destination.path.contains("/Library/CloudStorage/"), !destination.path.contains("/Library/Mobile Documents/") else { throw StoragePathError.unsafePath(destination.path) }
        for (old, new) in projectMappings { guard old.hasPrefix("/"), new.hasPrefix("/"), FileManager.default.fileExists(atPath: new) else { throw StoragePathError.unsafePath(new) } }
        guard Set(payloads.map { $0.metadata.sessionID }).count == payloads.count else { throw AgentSessionError.conflict }
        var existing: [String: (String, Data)] = [:]
        if FileManager.default.fileExists(atPath: destination.path) {
            for path in try CodexSessionAdapter().rolloutPaths(root: destination) {
                let data = try CodexSessionAdapter.read(CodexSessionAdapter.safeURL(path, under: destination), limit: CodexSessionAdapter.maximumRolloutBytes)
                let parsed = try CodexSessionAdapter.parse(data)
                guard existing[parsed.id] == nil else { throw AgentSessionError.conflict }
                existing[parsed.id] = (path, data)
            }
        }
        let items = try payloads.map { payload -> AgentRestorePlan.Item in
            _ = try payload.validated()
            let present = existing[payload.metadata.sessionID]
            let same = present?.1 == payload.rollout && projectMappings.isEmpty && payload.attachments.isEmpty && present?.0 == payload.metadata.relativePath
            return .init(payload: payload, existingPath: present?.0, disposition: present == nil ? .new : (same ? .identical : .conflict), existingData: present?.1)
        }
        return .init(destination: destination, items: items, projectMappings: projectMappings)
    }
    func execute(_ plan: AgentRestorePlan, replaceConflicts: Bool, allowPartial: Bool = false, executable: URL) throws -> URL {
        guard allowPartial || plan.items.allSatisfy({ $0.payload.isComplete }) else { throw AgentSessionError.changedSource }
        let selected = plan.items.filter { $0.disposition == .new || ($0.disposition == .conflict && replaceConflicts) }
        guard !selected.isEmpty else { throw AgentSessionError.conflict }
        let ids = Set(selected.map(\.id))
        // 子会话闭包由 UI 选择器提供；缺失的后代不能被默默省略。
        guard selected.allSatisfy({ item in item.payload.metadata.childIDs.allSatisfy { id in ids.contains(id) || plan.items.contains(where: { $0.id == id && $0.disposition == .identical }) } }) else { throw AgentSessionError.missingRelated }
        try Self.assertIdle(plan.destination)
        if let incomplete = try Self.pendingRecovery(at: plan.destination) { throw AgentSessionError.detail(L10n.string(.AgentSessions.errorRecoveryPath(incomplete.path))) }
        let validation = temporaryRoot.appendingPathComponent(UUID().uuidString)
        try ArcKitStoragePaths.secureDirectory(validation)
        defer { try? FileManager.default.removeItem(at: validation) }
        var prepared: [String: Data] = [:]
        var attachmentMappings: [String: [String: String]] = [:]
        for item in selected {
            var attachments: [String: String] = [:]
            for (index, attachment) in item.payload.attachments.enumerated() {
                let ext = URL(fileURLWithPath: attachment.originalPath).pathExtension
                let suffix = ext.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) && ext.count <= 12 ? ext : "bin"
                let path = "attachments/arc-kit/\(item.id)/\(UUID().uuidString)-\(index).\(suffix)"
                prepared[path] = attachment.data; attachments[attachment.originalPath] = plan.destination.appendingPathComponent(path).path
            }
            attachmentMappings[item.id] = attachments
            let raw = try Self.remap(item.payload.rollout, projects: plan.projectMappings, attachments: attachments)
            prepared[item.payload.metadata.relativePath] = raw
            let date = item.payload.metadata.createdAt
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let active = "sessions/\(formatter.string(from: date))/\(URL(fileURLWithPath: item.payload.metadata.relativePath).lastPathComponent)"
            try ArcKitAtomicFile.writeAtomically(raw, to: CodexSessionAdapter.safeURL(active, under: validation))
        }
        // 临时 Home、空工作目录和不可用的本地上游使恢复验证不能执行项目 Hook 或真实模型调用。
        let client = try CodexRecoveryClient(home: validation, executable: executable)
        var rows: [String: Row] = [:]
        do {
            if selected.contains(where: { $0.payload.historyProjection != nil }) {
                // 让当前 Codex 自己创建精确的分页 schema；临时会话不请求模型，随后删除。
                let bootstrap = try client.request("thread/start", ["cwd": client.workspace.path, "historyMode": "paginated", "approvalPolicy": "never", "sandbox": "read-only"])
                guard let id = (bootstrap["thread"] as? [String: Any])?["id"] as? String else { throw AgentSessionError.unsupportedFormat }
                _ = try client.request("thread/inject_items", ["threadId": id, "items": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Arc Kit temporary recovery schema"]]]]])
                _ = try client.request("thread/delete", ["threadId": id])
            }
            for item in selected {
                _ = try client.request("thread/read", ["threadId": item.id, "includeTurns": false])
                rows[item.id] = try Self.readOnly(validation.appendingPathComponent("state_5.sqlite")) { try Row.fetchOne($0, sql: "SELECT * FROM threads WHERE id=?", arguments: [item.id]) }
                if item.payload.metadata.parentID != nil {
                    if item.payload.metadata.historyMode == "paginated" {
                        guard let projection = item.payload.historyProjection else { throw AgentSessionError.detail(L10n.string(.AgentSessions.errorProjection)) }
                        guard let restored = prepared[item.payload.metadata.relativePath] else { throw AgentSessionError.invalidArchive }
                        // 结构化路径映射保留序号，并同步重定位每个原生字节边界。
                        let mapped = try projection.remapped(original: item.payload.rollout, restored: restored, projects: plan.projectMappings, attachments: attachmentMappings[item.id] ?? [:])
                        try mapped.install(at: validation, sessionID: item.id, byteCount: restored.count)
                    }
                    _ = try client.request("thread/read", ["threadId": item.id, "includeTurns": true])
                } else {
                    let reply = try client.request("thread/resume", ["threadId": item.id, "cwd": client.workspace.path, "modelProvider": "arckit_backup", "approvalPolicy": "never", "sandbox": "read-only", "excludeTurns": true])
                    guard (reply["thread"] as? [String: Any])?["id"] as? String == item.id else { throw AgentSessionError.invalidArchive }
                }
                _ = try client.request("thread/turns/list", ["threadId": item.id, "itemsView": "full", "limit": 1])
            }
            client.close()
        } catch { client.close(); throw error }
        let native = try DatabaseQueue(path: validation.appendingPathComponent("state_5.sqlite").path)
        try native.write { db in
            for item in selected {
                guard let original = rows[item.id] else { throw AgentSessionError.invalidArchive }
                let columns = original.columnNames.filter { $0 != "id" }
                let values = columns.map { original[$0] as DatabaseValue }
                try db.execute(sql: "UPDATE threads SET \(try columns.map { try Self.identifier($0) + "=?" }.joined(separator: ",")) WHERE id=?", arguments: StatementArguments(values + [item.id.databaseValue]))
                let m = item.payload.metadata
                try db.execute(sql: "UPDATE threads SET rollout_path=?,cwd=?,title=?,name=?,is_pinned=?,archived=? WHERE id=?", arguments: [plan.destination.appendingPathComponent(m.relativePath).path, plan.projectMappings[m.project] ?? m.project, m.title, m.title, m.pinned, m.archived, item.id])
                for attachment in m.linkedAttachments {
                    try db.execute(sql: "INSERT INTO thread_attachments(id,thread_id,attachment_type,identity_key,payload,created_at) VALUES (?,?,?,?,?,?)", arguments: [attachment.id, item.id, attachment.type, attachment.identityKey, attachment.payload, attachment.createdAt])
                }
                if let parent = m.parentID { try db.execute(sql: "INSERT INTO thread_spawn_edges(parent_thread_id,child_thread_id,status) VALUES (?,?,'completed') ON CONFLICT(child_thread_id) DO UPDATE SET parent_thread_id=excluded.parent_thread_id", arguments: [parent, item.id]) }
            }
        }
        try native.close()
        try Task.checkCancellation()
        try Self.assertIdle(plan.destination)
        // 确认页面显示之后若目标变化，重新规划，不能套用旧的覆盖决定。
        let fresh = try self.plan(plan.items.map(\.payload), destination: plan.destination, projectMappings: plan.projectMappings)
        guard zip(plan.items, fresh.items).allSatisfy({ $0.id == $1.id && $0.existingPath == $1.existingPath && $0.disposition == $1.disposition && $0.existingData == $1.existingData }) else { throw AgentSessionError.changedSource }
        try ArcKitStoragePaths.secureDirectory(plan.destination)
        let transaction = plan.destination.appendingPathComponent(".arc-kit-recovery/\(UUID().uuidString)")
        try ArcKitStoragePaths.secureDirectory(transaction)
        var keepRecovery = false
        defer { if !keepRecovery { try? FileManager.default.removeItem(at: transaction) } }
        let candidates = transaction.appendingPathComponent("prepared"); try ArcKitStoragePaths.secureDirectory(candidates)
        for (path, data) in prepared { try ArcKitAtomicFile.writeAtomically(data, to: CodexSessionAdapter.safeURL(path, under: candidates)) }
        let databaseFiles = Self.databases.filter { filename, _ in
            FileManager.default.fileExists(atPath: validation.appendingPathComponent(filename).path) || FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent(filename).path)
        }
        for (filename, tables) in databaseFiles {
            let source = validation.appendingPathComponent(filename)
            let target = plan.destination.appendingPathComponent(filename)
            let candidate = candidates.appendingPathComponent(filename)
            try Self.mergeDatabase(source: source, target: target, candidate: candidate, tables: tables, ids: selected.map(\.id))
        }
        var paths = Set(prepared.keys); paths.formUnion(databaseFiles.map(\.0))
        for item in selected { if let old = item.existingPath { paths.insert(old) } }
        for (filename, _) in databaseFiles { for suffix in ["-wal", "-shm", "-journal"] where FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent(filename + suffix).path) { paths.insert(filename + suffix) } }
        var journal = Journal(phase: "prepared", applied: 0, entries: paths.sorted().map { path in
            .init(path: path, existed: FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent(path).path), publish: FileManager.default.fileExists(atPath: candidates.appendingPathComponent(path).path))
        })
        try Self.write(journal, in: transaction)
        try Self.assertIdle(plan.destination)
        do {
            keepRecovery = true
            journal.phase = "applying"; try Self.write(journal, in: transaction)
            for (index, entry) in journal.entries.enumerated() {
                // 在移动之前记录意图，断电后也知道哪些路径可能已经改变。
                journal.applied = index + 1; try Self.write(journal, in: transaction)
                let target = try CodexSessionAdapter.safeURL(entry.path, under: plan.destination)
                if entry.existed {
                    let backup = try CodexSessionAdapter.safeURL(entry.path, under: transaction.appendingPathComponent("original"))
                    try ArcKitStoragePaths.secureDirectory(backup.deletingLastPathComponent())
                    try FileManager.default.moveItem(at: target, to: backup)
                    try ArcKitStoragePaths.synchronizeDirectory(backup.deletingLastPathComponent())
                    try ArcKitStoragePaths.synchronizeDirectory(target.deletingLastPathComponent())
                }
                if entry.publish {
                    try ArcKitStoragePaths.secureDirectory(target.deletingLastPathComponent())
                    try FileManager.default.moveItem(at: candidates.appendingPathComponent(entry.path), to: target)
                    try ArcKitStoragePaths.synchronizeDirectory(target.deletingLastPathComponent())
                }
            }
            for (path, data) in prepared {
                guard try CodexSessionAdapter.read(CodexSessionAdapter.safeURL(path, under: plan.destination), limit: AgentSessionArchive.maximumBytes) == data else { throw AgentSessionError.invalidArchive }
            }
            journal.phase = "complete"; try Self.write(journal, in: transaction)
            return transaction
        } catch {
            do { try Self.rollback(transaction, destination: plan.destination) }
            catch { throw AgentSessionError.detail(L10n.string(.AgentSessions.errorRecoveryPath(transaction.path))) }
            throw error
        }
    }
    static func pendingRecovery(at root: URL) throws -> URL? {
        let folder = try CodexSessionAdapter.safeURL(".arc-kit-recovery", under: root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let url = entry.standardizedFileURL
            let file = url.appendingPathComponent("journal.plist")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let journal = try PropertyListDecoder().decode(Journal.self, from: CodexSessionAdapter.read(file, limit: 8 * 1_024 * 1_024))
            if journal.phase == "applying" { return url }
        }
        return nil
    }
    static func rollback(_ transaction: URL, destination: URL) throws {
        try assertIdle(destination)
        guard transaction.deletingLastPathComponent().path == destination.appendingPathComponent(".arc-kit-recovery").path else { throw AgentSessionError.invalidArchive }
        var journal = try PropertyListDecoder().decode(Journal.self, from: CodexSessionAdapter.read(transaction.appendingPathComponent("journal.plist"), limit: 8 * 1_024 * 1_024))
        guard journal.phase == "applying", (0...journal.entries.count).contains(journal.applied), journal.entries.count <= 20_000,
              Set(journal.entries.map(\.path)).count == journal.entries.count, journal.entries.allSatisfy({ recoveryPath($0.path) }) else { throw AgentSessionError.invalidArchive }
        for entry in journal.entries.prefix(journal.applied).reversed() {
            let original = try CodexSessionAdapter.safeURL(entry.path, under: transaction.appendingPathComponent("original"))
            let target = try CodexSessionAdapter.safeURL(entry.path, under: destination)
            if entry.existed {
                if FileManager.default.fileExists(atPath: original.path) {
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.moveItem(at: original, to: target)
                }
            } else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        journal.phase = "rolledBack"; try write(journal, in: transaction)
    }
    private static func recoveryPath(_ path: String) -> Bool {
        if CodexSessionAdapter.isRolloutPath(path) { return true }
        if path.hasPrefix("attachments/arc-kit/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) { return true }
        return databases.contains { filename, _ in ["", "-wal", "-shm", "-journal"].contains { path == filename + $0 } }
    }
    private static func write(_ journal: Journal, in root: URL) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try ArcKitAtomicFile.writeAtomically(encoder.encode(journal), to: root.appendingPathComponent("journal.plist"))
    }
    private static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { throw AgentSessionError.unsupportedFormat }
        return "\"" + value + "\""
    }
    private static func readOnly<T>(_ file: URL, _ action: (Database) throws -> T) throws -> T {
        try CodexSessionAdapter.readDatabase(file, action)
    }
    private static func mergeDatabase(source: URL, target: URL, candidate: URL, tables: [(String, String)], ids: [String]) throws {
        let output = try DatabaseQueue(path: candidate.path); defer { try? output.close() }
        let exists = FileManager.default.fileExists(atPath: target.path)
        try CodexSessionAdapter.withReadOnlyQueue(exists ? target : source) { try $0.backup(to: output) }
        if exists {
            try output.write { db in
                let hasProjection = FileManager.default.fileExists(atPath: source.path)
                if hasProjection { try db.execute(sql: "ATTACH DATABASE ? AS restored", arguments: [source.path]) }
                // legacy-only 恢复没有分页索引；只删除被替换 ID 的旧投影，其他会话保持原样。
                for (table, key) in tables {
                    if !hasProjection {
                        for id in ids { try db.execute(sql: "DELETE FROM \(try identifier(table)) WHERE \(try identifier(key))=?", arguments: [id]) }
                        continue
                    }
                    let targetColumns = try db.columns(in: table).map(\.name)
                    let restoredColumns = try Row.fetchAll(db, sql: "PRAGMA restored.table_info(\(try identifier(table)))").compactMap { String.fromDatabaseValue($0["name"]) }
                    guard targetColumns == restoredColumns else {
                        throw AgentSessionError.detail(L10n.string(.AgentSessions.errorSchema(table)))
                    }
                    let names = try targetColumns.map(identifier).joined(separator: ",")
                    for id in ids {
                        try db.execute(sql: "DELETE FROM \(try identifier(table)) WHERE \(try identifier(key))=?", arguments: [id])
                        try db.execute(sql: "INSERT INTO \(try identifier(table)) (\(names)) SELECT \(names) FROM restored.\(try identifier(table)) WHERE \(try identifier(key))=?", arguments: [id])
                    }
                }
            }
        }
        try output.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok" else { throw AgentSessionError.invalidArchive }
        }
        try output.close(); try ArcKitStoragePaths.secureFile(candidate)
    }
    static func assertIdle(_ root: URL) throws {
        let files = ["state_5.sqlite", "thread_history_1.sqlite"].map { root.appendingPathComponent($0).path }.filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return }
        let process = Process(); let pipe = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-t", "--"] + files
        process.standardOutput = pipe; process.standardError = errors
        process.environment = ArcKitSubprocessEnvironment.sanitized()
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); let errorOutput = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard errorOutput.isEmpty else { throw AgentSessionError.detail(L10n.string(.AgentSessions.errorIdleCheck)) }
        guard process.terminationStatus == 1 && output.isEmpty else { throw AgentSessionError.busyTarget }
    }
    static func remap(_ data: Data, projects: [String: String], attachments: [String: String]) throws -> Data {
        guard !projects.isEmpty || !attachments.isEmpty else { return data }
        func change(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if let cwd = object["cwd"] as? String, let new = projects[cwd] { object["cwd"] = new }
                for key in ["runtime_workspace_roots", "local_images"] {
                    if let paths = object[key] as? [String] { object[key] = paths.map { key == "local_images" ? attachments[$0] ?? $0 : projects[$0] ?? $0 } }
                }
                if object["type"] as? String == "local_image", let path = object["path"] as? String, let new = attachments[path] { object["path"] = new }
                for (key, child) in object where child is [String: Any] || child is [Any] { object[key] = change(child) }
                return object
            }
            if let values = value as? [Any] { return values.map(change) }
            return value
        }
        var result = Data()
        for object in try CodexSessionAdapter.objects(data) { result.append(try JSONSerialization.data(withJSONObject: change(object), options: [.sortedKeys, .fragmentsAllowed])); result.append(10) }
        return result
    }
}
