import ArcKitPlatform
import Foundation

/// 只在用户导出时读取有界日志；不包含数据库、媒体、进程身份凭证或完整配置。
enum SupportDiagnosticPackage {
    static var privacyNotice: String { L10n.string(.Diagnostics.packageContents) }
    private struct Package: Encodable {
        let format = 1
        let summary: SupportDiagnosticReport
        let logs: [String: String]
        let collectionNotes: [String]
    }
    static func save(_ report: SupportDiagnosticReport, to url: URL, paths: ArcKitStoragePaths = .current) throws {
        ArcKitLog.flush()
        var logs: [String: String] = [:]
        var notes = [L10n.string(.Diagnostics.packageFinderExtensionWrites), L10n.string(.Diagnostics.packageRecentLogLimit)]
        for component in ["app", "host", "worker"] {
            let file = paths.logs.appendingPathComponent(component + ".jsonl")
            do {
                try ArcKitStoragePaths.validateFile(file)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let offset = size > 1_048_576 ? size - 1_048_576 : 0
                try handle.seek(toOffset: offset)
                var bytes = try handle.read(upToCount: 1_048_576) ?? Data()
                if offset > 0, let newline = bytes.firstIndex(of: 10) { bytes = bytes.suffix(from: bytes.index(after: newline)) }
                logs[component] = ArcKitLog.redact(String(decoding: bytes, as: UTF8.self))
            } catch { notes.append(component + L10n.string(.Diagnostics.packageLogsUnavailable)) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Package(summary: report, logs: logs, collectionNotes: notes))
        try ArcKitAtomicFile.writeAtomically(data, to: url)
        // 外部另存文件不受保留策略管理；本地诊断副本最多 10 份、30 天。
        try ArcKitStoragePaths.secureDirectory(paths.diagnostics)
        try ArcKitAtomicFile.writeAtomically(data, to: paths.diagnostics.appendingPathComponent("support-\(UUID().uuidString).json"))
    }
}
