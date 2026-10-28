#if DEBUG
import ArcKitFinder
import ArcKitPersistence
import ArcKitPlatform
import AppKit
import Darwin
import SwiftUI

/// 隔离验收入口，先于生产 StorageBootstrap 分流。不会安装应用或注册系统后台。
@MainActor
public enum AgentSessionDevelopment {
    public static func handle(arguments: [String]) -> Int32? {
        if arguments.count == 3, arguments[1] == "--agent-sessions-render" {
            let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
            Task {
                do { try await render(to: URL(fileURLWithPath: arguments[2])); Darwin.exit(0) }
                catch { print("AGENT_SESSION_RENDER_FAILED \(error)"); Darwin.exit(1) }
            }
            app.run(); return 0
        }
        if arguments.count == 5, arguments[1] == "--agent-sessions-check" {
            Task.detached {
                do {
                    try check(source: URL(fileURLWithPath: arguments[2]), output: URL(fileURLWithPath: arguments[3]), executable: URL(fileURLWithPath: arguments[4]))
                    Darwin.exit(0)
                } catch { print("AGENT_SESSION_CHECK_FAILED \(error)"); Darwin.exit(1) }
            }
            dispatchMain()
        }
        if arguments.contains("--ui-debug"), arguments.contains("--agent-sessions") { return nil }
        if arguments.contains(where: { $0.hasPrefix("--agent-sessions") }) {
            print("Usage: ArcKitApp --agent-sessions-render <new-directory> | --agent-sessions-check <fixture-home> <new-output> <codex-executable>")
            return 2
        }
        return nil
    }
    private nonisolated static func check(source: URL, output: URL, executable: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try ArcKitStoragePaths.secureDirectory(output)
        let repository = SettingsRepository(directoryURL: output.appendingPathComponent("arc-kit")); _ = try repository.load()
        defer { try? repository.database.close() }
        let store = AgentSessionStore(database: repository.database)
        let source = AgentSessionSource(name: "Native Codex fixture", path: source.path)
        let scan = try CodexSessionAdapter().scan([source])
        guard scan.sourceErrors.isEmpty, scan.rows.count >= 2 else { throw AgentSessionError.detail("Fixture scan: count=\(scan.rows.count), errors=\(scan.sourceErrors)") }
        var payloads = try scan.rows.map { try CodexSessionAdapter().capture($0, source: source) }
        let captured = Date(); for index in payloads.indices { payloads[index].capturedAt = captured }
        print("AGENT_SESSION_CHECK captured=\(payloads.count)")
        let versions = try store.saveBatch(payloads, capacityBytes: 100_000_000)
        print("AGENT_SESSION_CHECK persisted=\(versions.count)")
        let archive = output.appendingPathComponent("native.arckitsessions")
        try AgentSessionArchive.export(payloads, password: "isolated-native-fixture-2026", to: archive)
        let decoded = try AgentSessionArchive.load(from: archive, password: "isolated-native-fixture-2026")
        guard decoded == payloads else { throw AgentSessionError.detail("Encrypted archive round-trip mismatch") }
        let destination = output.appendingPathComponent("restored-codex")
        let service = CodexSessionRestore(temporaryRoot: repository.database.paths.temporary)
        let mappedProject = output.appendingPathComponent("mapped-project")
        try ArcKitStoragePaths.secureDirectory(mappedProject)
        let mappings = Dictionary(uniqueKeysWithValues: Set(decoded.map { $0.metadata.project }).map { ($0, mappedProject.path) })
        let plan = try service.plan(decoded, destination: destination, projectMappings: mappings)
        let recovery = try service.execute(plan, replaceConflicts: false, executable: executable)
        print("AGENT_SESSION_CHECK restored=\(destination.path) count=\(decoded.count)")
        let client = try CodexRecoveryClient(home: destination, executable: executable)
        var results: [[String: Any]] = []
        do {
            for payload in decoded {
                let id = payload.metadata.sessionID
                let read = try client.request("thread/read", ["threadId": id, "includeTurns": true])
                guard let thread = read["thread"] as? [String: Any], let turns = thread["turns"] as? [[String: Any]], !turns.isEmpty,
                      thread["name"] as? String == payload.metadata.title, thread["cwd"] as? String == mappedProject.path else { throw AgentSessionError.invalidArchive }
                let items = turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }
                guard items.contains(where: { $0["type"] as? String == "agentMessage" }) else { throw AgentSessionError.invalidArchive }
                if let parent = payload.metadata.parentID {
                    let source = thread["source"] as? [String: Any]
                    let spawned = (source?["subAgent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
                    guard spawned?["parent_thread_id"] as? String == parent else { throw AgentSessionError.invalidArchive }
                }
                results.append(["id": id, "historyMode": payload.metadata.historyMode, "turns": turns.count, "items": items.count, "title": payload.metadata.title])
            }
            client.close()
        } catch { client.close(); throw error }
        print("AGENT_SESSION_CHECK nativeReadback=passed")
        // 替换一个会话，检查另一个会话的原始日志未被修改。
        guard let original = decoded.first(where: { $0.metadata.parentID == nil && $0.metadata.childIDs.isEmpty }),
              let unrelated = decoded.first(where: { $0.metadata.sessionID != original.metadata.sessionID }) else { throw AgentSessionError.invalidArchive }
        var changed = original
        changed.rollout = Data(String(decoding: changed.rollout, as: UTF8.self).replacingOccurrences(of: "native recovery fixture response", with: "updated recovery fixture response").utf8)
        guard changed.rollout != original.rollout else { throw AgentSessionError.invalidArchive }
        let otherURL = destination.appendingPathComponent(unrelated.metadata.relativePath)
        let otherBefore = try Data(contentsOf: otherURL)
        let replacement = try service.plan([changed], destination: destination)
        guard replacement.conflictCount == 1 else { throw AgentSessionError.invalidArchive }
        _ = try service.execute(replacement, replaceConflicts: true, executable: executable)
        guard try Data(contentsOf: otherURL) == otherBefore else { throw AgentSessionError.invalidArchive }
        let report: [String: Any] = ["codexVersion": "0.163.0", "sessions": results, "backupVersions": versions.count, "encryptedRoundTrip": true, "nativeReadback": true, "projectMapping": true, "unrelatedSessionPreserved": true, "recovery": recovery.path]
        try ArcKitAtomicFile.writeAtomically(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), to: output.appendingPathComponent("acceptance.json"))
        print("AGENT_SESSION_CHECK_OK evidence=\(output.appendingPathComponent("acceptance.json").path)")
    }
    private static func render(to output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try ArcKitStoragePaths.secureDirectory(output)
        let repository = SettingsRepository(directoryURL: output.appendingPathComponent("app")); _ = try repository.load()
        let settings = SettingsModel(store: repository, templateLibrary: NewFileTemplateLibrary(baseDirectory: repository.database.paths.templates))
        await settings.waitForPendingChanges()
        let store = AgentSessionStore(database: repository.database)
        let names = ["菜单栏交互与快捷键", "发布前检查与回滚方案", "文件预览体验调整", "会话备份与恢复", "梳理窗口场景切换", "API 流式响应排查"]
        for (index, name) in names.enumerated() {
            let id = UUID().uuidString.lowercased()
            let project = "/Projects/" + ["arc-kit", "arc-home", "arc-kit", "arc-kit", "arc-kit", "agent-tools"][index]
            let records: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": id, "timestamp": "2026-10-23T00:00:00Z", "cwd": project, "cli_version": "0.163.0", "history_mode": "legacy", "source": "cli", "model_provider": "openai"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "先整理交互，再实现。保留现有功能，给出可以验证的结果。"]]]],
                ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "我会先检查现有的数据流与状态归属。\n\n本次调整集中在三点：\n1. 让默认操作更容易找到。\n2. 将失败与恢复放在同一个流程。\n3. 保留必要的原始记录，方便之后回查。"]]]],
                ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "arguments": "swift test --filter SessionTests"]]
            ]
            var raw = Data(); for record in records { raw.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); raw.append(10) }
            let date = Date().addingTimeInterval(Double(-index) * 7200)
            let metadata = AgentSessionMetadata(sessionID: id, title: name, project: project, createdAt: date, modifiedAt: date, cliVersion: "0.163.0", historyMode: "legacy", archived: index == 4, childIDs: [], pinned: false, relativePath: "sessions/2026/10/23/rollout-2026-10-23T00-00-00-\(id).jsonl", modelProvider: "openai")
            let payload = AgentSessionPayload(sourceID: UUID(uuidString: "018f2100-0000-7000-8000-000000000000")!, sourceName: "Codex · MacBook", capturedAt: date, metadata: metadata, rollout: raw, attachments: [], missingAttachments: [], incompleteBytes: index == 2 ? 8 : 0, changedDuringRead: false)
            if index == 0 {
                var old = payload
                old.capturedAt = date.addingTimeInterval(-86400)
                old.metadata.project = "/Projects/arc-kit-legacy"
                old.rollout = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "我会先检查现有的数据流与状态归属。", with: "旧项目中的迁移检查记录。").replacingOccurrences(of: "arc-kit", with: "arc-kit-legacy").utf8)
                _ = try store.save(old, capacityBytes: 10_000_000)
            }
            _ = try store.save(payload, capacityBytes: 10_000_000)
        }
        let model = AgentSessionModel(settings: settings, isPreview: true); model.start(); await model.waitUntilIdle()
        let selection = Set(model.rows.prefix(1).map(\.id))
        for (file, size, scheme) in [("sessions-light.png", CGSize(width: 1000, height: 720), ColorScheme.light), ("sessions-dark.png", CGSize(width: 1000, height: 720), .dark), ("sessions-narrow.png", CGSize(width: 760, height: 650), .light)] {
            L10n.configure(.simplifiedChinese)
            try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSelection: selection), size: size, scheme: scheme, to: output.appendingPathComponent(file))
        }
        L10n.configure(.english)
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSelection: selection), size: CGSize(width: 760, height: 650), scheme: .light, to: output.appendingPathComponent("sessions-english.png"))
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor), size: CGSize(width: 540, height: 500), scheme: .light, to: output.appendingPathComponent("sessions-compact-list.png"))
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSelection: selection), size: CGSize(width: 540, height: 500), scheme: .light, to: output.appendingPathComponent("sessions-compact-detail.png"))
        // 用正式搜索和定位入口渲染消息结果，不用第二份演示列表冒充可用搜索。
        let query = "数据流"
        model.searchBackups(.init(text: query, sourceID: nil, project: "")); await model.waitUntilSearchFinishes()
        guard let hit = model.searchResult.hits.first else { throw AgentSessionError.invalidArchive }
        L10n.configure(.simplifiedChinese)
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSearch: query),
                        size: CGSize(width: 1000, height: 720), scheme: .light, to: output.appendingPathComponent("search-messages.png"))
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSearch: query, initialHit: hit),
                        size: CGSize(width: 1000, height: 720), scheme: .dark, to: output.appendingPathComponent("search-message-focus.png"))
        L10n.configure(.english)
        try await image(AgentSessionsSection(model: model, settings: settings.agentSessionsEditor, initialSearch: query),
                        size: CGSize(width: 540, height: 500), scheme: .light, to: output.appendingPathComponent("search-compact-english.png"))
        let payloads = try model.versions.prefix(2).map { try store.payload($0) }
        try await image(AgentSessionRestoreSheet(request: .init(payloads: payloads), model: model), size: CGSize(width: 640, height: 670), scheme: .light, to: output.appendingPathComponent("restore-sheet.png"))
        L10n.configure(.simplifiedChinese)
        let source = output.appendingPathComponent("sample-codex"); try ArcKitStoragePaths.secureDirectory(source)
        settings.agentSessionsEditor.update { $0.sources = [.init(name: "Codex · MacBook", path: source.path)] }
        _ = await settings.finishPendingChanges()
        try await image(AgentSessionSourcesSheet(settings: settings.agentSessionsEditor, errors: [:], isPreview: true), size: CGSize(width: 600, height: 580), scheme: .light, to: output.appendingPathComponent("sources-sheet.png"))
        await model.suspendAndWait(); try repository.database.close()
        print("AGENT_SESSION_RENDER_OK directory=\(output.path)")
    }
    private static func image<Content: View>(_ view: Content, size: CGSize, scheme: ColorScheme, to url: URL) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua); window.contentView = host
        host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
#endif
