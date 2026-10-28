import ArcKitPersistence
import ArcKitPlatform
import Foundation
import ImageIO

/// 仅读取明确选择的 CODEX_HOME。正文不经 app-server，发现和备份不会启动 Agent。
struct CodexSessionAdapter: Sendable {
    static let maximumRolloutBytes = 256 * 1_024 * 1_024
    static let maximumAttachmentBytes = 32 * 1_024 * 1_024
    struct Parsed {
        var id: String
        var cwd: String
        var createdAt: Date
        var version: String
        var mode: String
        var provider: String
        var parent: String?
        var forkedFrom: String?
        var title: String
        var completeLength: Int
        var attachmentPaths: Set<String>
    }
    struct NativeMetadata {
        var title: String?
        var pinned: Bool
        var parent: String?
        var children: [String]
        var linkedAttachments: [CodexLinkedAttachment] = []
    }

    static func isRolloutPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && ["sessions", "archived_sessions"].contains(String(parts[0])) &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") } &&
            parts.last!.hasPrefix("rollout-") && parts.last!.hasSuffix(".jsonl")
    }
    static func safeURL(_ path: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw StoragePathError.unsafePath(path) }
        return url
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        try ArcKitStoragePaths.validateFile(url)
        return try ArcKitBoundedFileReader.read(from: url, maximumBytes: limit)
    }
    static func withReadOnlyQueue<T>(_ file: URL, _ action: (DatabaseQueue) throws -> T) throws -> T {
        try ArcKitStoragePaths.validateFile(file)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let shm = URL(fileURLWithPath: file.path + "-shm")
        for sidecar in [wal, shm] where FileManager.default.fileExists(atPath: sidecar.path) { try ArcKitStoragePaths.validateFile(sidecar) }
        let hasWAL = FileManager.default.fileExists(atPath: wal.path)
        let before = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var path = file.path
        if !hasWAL {
            // macOS SQLite 只读打开已关闭的 WAL 库时不能创建共享内存。
            // 仅在无 WAL 的稳定主文件上使用 immutable，结束后再次核对，绝不忽略现有 WAL。
            var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "mode", value: "ro"), .init(name: "immutable", value: "1")]
            path = components.string!
        }
        var config = Configuration(); config.readonly = true; config.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: path, configuration: config); defer { try? queue.close() }
        let result = try action(queue)
        if !hasWAL {
            let after = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard !FileManager.default.fileExists(atPath: wal.path), before.fileSize == after.fileSize,
                  before.contentModificationDate == after.contentModificationDate else { throw AgentSessionError.changedSource }
        }
        return result
    }
    static func readDatabase<T>(_ file: URL, _ action: (Database) throws -> T) throws -> T {
        try withReadOnlyQueue(file) { try $0.read(action) }
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func objects(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 10).map {
            guard let value = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else { throw AgentSessionError.unsupportedFormat }
            return value
        }
    }
    static func parse(_ data: Data) throws -> Parsed {
        guard let end = data.lastIndex(of: 10) else { throw AgentSessionError.changedSource }
        let length = data.distance(from: data.startIndex, to: end) + 1
        let lines = data.prefix(length).split(separator: 10)
        guard let line = lines.first, let first = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], first["type"] as? String == "session_meta", let meta = first["payload"] as? [String: Any],
              let id = meta["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = meta["cwd"] as? String, let created = date(meta["timestamp"] as? String),
              let version = meta["cli_version"] as? String else { throw AgentSessionError.unsupportedFormat }
        let mode = meta["history_mode"] as? String ?? "legacy" // Codex 的 legacy 日志原生省略 history_mode。
        guard ["legacy", "paginated"].contains(mode) else { throw AgentSessionError.unsupportedFormat }
        var ordinal: Int64 = -1
        var title = ""
        var paths = Set<String>()
        for line in lines {
            try Task.checkCancellation()
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw AgentSessionError.unsupportedFormat }
            if mode == "paginated" {
                guard let next = (record["ordinal"] as? NSNumber)?.int64Value, next > ordinal else { throw AgentSessionError.unsupportedFormat }
                ordinal = next
            }
            guard let payload = record["payload"] as? [String: Any] else { throw AgentSessionError.unsupportedFormat }
            if record["type"] as? String == "event_msg", payload["type"] as? String == "user_message", title.isEmpty {
                title = String((payload["message"] as? String ?? "").prefix(160)).replacingOccurrences(of: "\n", with: " ")
            }
            if title.isEmpty, payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" {
                let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                title = String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
            }
            collectAttachments(payload, into: &paths)
        }
        let spawn = ((meta["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
        return Parsed(id: id, cwd: cwd, createdAt: created, version: version, mode: mode,
            provider: meta["model_provider"] as? String ?? "openai", parent: spawn?["parent_thread_id"] as? String,
            forkedFrom: meta["forked_from_id"] as? String, title: title.isEmpty ? id : title,
            completeLength: length, attachmentPaths: paths)
    }
    private static func collectAttachments(_ object: Any, into paths: inout Set<String>) {
        if let value = object as? [String: Any] {
            if let images = value["local_images"] as? [String] { paths.formUnion(images.filter { $0.hasPrefix("/") }) }
            if value["type"] as? String == "local_image", let path = value["path"] as? String { paths.insert(path) }
            for item in value.values { if item is [String: Any] || item is [Any] { collectAttachments(item, into: &paths) } }
        } else if let array = object as? [Any] { for item in array { collectAttachments(item, into: &paths) } }
    }

    func scan(_ sources: [AgentSessionSource], previous: [AgentSessionRow] = []) throws -> AgentSessionScan {
        var result = AgentSessionScan()
        for source in sources {
            try Task.checkCancellation()
            do {
                let root = URL(fileURLWithPath: source.path)
                guard root.resolvingSymlinksInPath().path == root.path,
                      try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw StoragePathError.unsafePath(source.path) }
                let native = try metadata(root: root)
                var rows: [AgentSessionRow] = []
                var seen = Set<String>()
                var fileErrors: [String] = []
                for relative in try rolloutPaths(root: root) {
                    try Task.checkCancellation()
                    do {
                    let url = try Self.safeURL(relative, under: root)
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let p: Parsed
                    if let cached = previous.first(where: { $0.key.sourceID == source.id && $0.metadata.relativePath == relative && $0.metadata.sourceByteCount == values.fileSize && $0.metadata.modifiedAt == values.contentModificationDate }) {
                        let m = cached.metadata
                        p = Parsed(id: m.sessionID, cwd: m.project, createdAt: m.createdAt, version: m.cliVersion, mode: m.historyMode, provider: m.modelProvider, parent: m.parentID, forkedFrom: m.forkedFromID, title: m.title, completeLength: m.sourceByteCount, attachmentPaths: [])
                    } else { p = try Self.parse(Self.read(url, limit: Self.maximumRolloutBytes)) }
                    guard seen.insert(p.id).inserted else { throw AgentSessionError.detail(L10n.string(.AgentSessions.errorDuplicate(p.id))) }
                    let m = native[p.id]
                    let modified = values.contentModificationDate ?? p.createdAt
                    let metadata = AgentSessionMetadata(sessionID: p.id, title: m?.title ?? p.title, project: p.cwd, createdAt: p.createdAt, modifiedAt: modified, sourceByteCount: values.fileSize ?? 0,
                        cliVersion: p.version, historyMode: p.mode, archived: relative.hasPrefix("archived_sessions/"), parentID: m?.parent ?? p.parent,
                        forkedFromID: p.forkedFrom, childIDs: m?.children ?? [], linkedAttachments: m?.linkedAttachments ?? [], pinned: m?.pinned ?? false, relativePath: relative, modelProvider: p.provider)
                    rows.append(.init(key: .init(sourceID: source.id, sessionID: p.id), metadata: metadata, sourceName: source.name, sourcePath: source.path, sourceMissing: false))
                    } catch { fileErrors.append(URL(fileURLWithPath: relative).lastPathComponent + ": " + error.localizedDescription) }
                }
                // 日志中的父子边也参与闭包，不依赖索引库是否已经完成回填。
                for index in rows.indices {
                    rows[index].metadata.childIDs = Array(Set(rows[index].metadata.childIDs + rows.filter { $0.metadata.parentID == rows[index].key.sessionID }.map { $0.key.sessionID })).sorted()
                }
                result.rows += rows
                if fileErrors.isEmpty { result.scannedSources.insert(source.id) }
                else { result.sourceErrors[source.id] = fileErrors.prefix(5).joined(separator: "\n") }
            } catch is CancellationError { throw CancellationError() }
            catch { result.sourceErrors[source.id] = error.localizedDescription }
        }
        return result
    }
    func rolloutPaths(root: URL) throws -> [String] {
        var paths: [String] = []
        for name in ["sessions", "archived_sessions"] {
            let directory = try Self.safeURL(name, under: root)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw StoragePathError.unsafePath(file.path) }
                if values.isRegularFile == true, file.pathExtension == "jsonl", file.lastPathComponent.hasPrefix("rollout-") {
                    let normalized = file.standardizedFileURL.path
                    guard normalized.hasPrefix(root.standardizedFileURL.path + "/") else { throw StoragePathError.unsafePath(normalized) }
                    paths.append(String(normalized.dropFirst(root.standardizedFileURL.path.count + 1)))
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return paths.sorted()
    }
    private func metadata(root: URL) throws -> [String: NativeMetadata] {
        let file = try Self.safeURL("state_5.sqlite", under: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try Self.readDatabase(file) { db in
            // 元数据只取白名单列，不读取登录、远控注册或整个数据库内容。
            let columns = Set(try db.columns(in: "threads").map(\.name))
            guard Set(["id", "title", "name", "is_pinned"]).isSubset(of: columns) else { throw AgentSessionError.unsupportedFormat }
            var records: [String: NativeMetadata] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id,title,name,is_pinned FROM threads") {
                guard let id = String.fromDatabaseValue(row["id"]), let title = String.fromDatabaseValue(row["title"]), let pin = Bool.fromDatabaseValue(row["is_pinned"]) else { throw AgentSessionError.unsupportedFormat }
                let name = String.fromDatabaseValue(row["name"])
                records[id] = .init(title: (name?.isEmpty == false ? name : (title.isEmpty ? nil : title)), pinned: pin, children: [])
            }
            if try db.tableExists("thread_spawn_edges") {
                for row in try Row.fetchAll(db, sql: "SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges") {
                    guard let parent = String.fromDatabaseValue(row["parent_thread_id"]), let child = String.fromDatabaseValue(row["child_thread_id"]) else { throw AgentSessionError.unsupportedFormat }
                    records[child]?.parent = parent; records[parent]?.children.append(child)
                }
            }
            if try db.tableExists("thread_attachments") {
                for row in try Row.fetchAll(db, sql: "SELECT id,thread_id,attachment_type,identity_key,payload,created_at FROM thread_attachments") {
                    guard let id = String.fromDatabaseValue(row["id"]), let thread = String.fromDatabaseValue(row["thread_id"]),
                          let type = String.fromDatabaseValue(row["attachment_type"]), let identity = String.fromDatabaseValue(row["identity_key"]),
                          let payload = String.fromDatabaseValue(row["payload"]), let created = Int64.fromDatabaseValue(row["created_at"]), payload.utf8.count <= 1_048_576 else { throw AgentSessionError.unsupportedFormat }
                    records[thread]?.linkedAttachments.append(.init(id: id, type: type, identityKey: identity, payload: payload, createdAt: created))
                }
            }
            return records
        }
    }
    func capture(_ row: AgentSessionRow, source: AgentSessionSource) throws -> AgentSessionPayload {
        let url = try Self.safeURL(row.metadata.relativePath, under: URL(fileURLWithPath: source.path))
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let bytes = try Self.read(url, limit: Self.maximumRolloutBytes)
        let p = try Self.parse(bytes)
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard p.id == row.key.sessionID else { throw AgentSessionError.changedSource }
        var attachments: [AgentSessionAttachment] = []
        // 链接型附件保留原生引用，但云端内容不在本地文件白名单中，明确标记未打包。
        var missing = row.metadata.linkedAttachments.map { "linked:" + $0.identityKey }
        guard p.attachmentPaths.count <= 256 else { throw AgentSessionError.invalidArchive }
        for path in p.attachmentPaths.sorted() {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let authorized = ([source.path] + source.attachmentRoots).contains { file.path.hasPrefix($0 + "/") }
            let imageType = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "avif"].contains(file.pathExtension.lowercased())
            // local_image 只允许实际图片；日志中的路径不能把 auth.json、配置或私钥伪装成附件。
            let beforeImage = imageType && authorized ? try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) : nil
            if let beforeImage, let data = try? Self.read(file, limit: Self.maximumAttachmentBytes),
               let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
               let afterImage = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
               beforeImage.fileSize == afterImage.fileSize, beforeImage.contentModificationDate == afterImage.contentModificationDate {
                guard bytes.count + attachments.reduce(0, { $0 + $1.data.count }) + data.count <= AgentSessionArchive.maximumBytes - 1_048_576 else { throw AgentSessionError.capacity }
                attachments.append(.init(originalPath: path, data: data))
            }
            else { missing.append(path) }
        }
        var metadata = row.metadata; metadata.modifiedAt = before.contentModificationDate ?? row.metadata.modifiedAt
        metadata.sourceByteCount = before.fileSize ?? bytes.count
        let needsProjection = p.mode == "paginated" && metadata.parentID != nil
        let projection = needsProjection ? try CodexHistoryProjection.capture(root: URL(fileURLWithPath: source.path), sessionID: p.id, byteCount: p.completeLength) : nil
        let finalValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return try AgentSessionPayload(sourceID: source.id, sourceName: source.name, capturedAt: Date(), metadata: metadata,
            rollout: Data(bytes.prefix(p.completeLength)), attachments: attachments, historyProjection: projection, missingProjection: needsProjection && projection == nil, missingAttachments: missing,
            incompleteBytes: bytes.count - p.completeLength,
            changedDuringRead: before.fileSize != row.metadata.sourceByteCount || before.contentModificationDate != row.metadata.modifiedAt || before.fileSize != after.fileSize || before.contentModificationDate != after.contentModificationDate || before.fileSize != finalValues.fileSize || before.contentModificationDate != finalValues.contentModificationDate).validated()
    }
    static func transcript(_ data: Data) throws -> [AgentTranscriptEntry] {
        var result: [AgentTranscriptEntry] = []
        for (index, object) in try objects(data).enumerated() {
            guard let p = object["payload"] as? [String: Any], let type = p["type"] as? String else { continue }
            if object["type"] as? String == "response_item" {
                if type == "message", let role = p["role"] as? String {
                    let text = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { result.append(.init(id: index, kind: role, text: text)) }
                } else if ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output"].contains(type) {
                    let value = p["arguments"] ?? p["output"] ?? p["input"] ?? ""
                    let text = try (value as? String) ?? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
                    result.append(.init(id: index, kind: p["name"] as? String ?? type, text: text))
                }
            }
        }
        return result
    }
}
