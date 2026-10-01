import Foundation
import os

/// 输入回调只入有界队列。组件独立轮卷，无新日志服务，也不为日志唤醒 Host。
public enum ArcKitLog {
    private static let sink = Sink()
    public static var fileURL: URL { ArcKitStoragePaths.current.logs.appendingPathComponent("\(component).jsonl") }
    public static var component: String {
        if CommandLine.arguments.contains("--operation-worker") { return "worker" }
        return ProcessInfo.processInfo.processName.contains("RuntimeHost") ? "host" : "app"
    }
    public static func append(_ message: String) { sink.append(message) }
    public static func shouldWriteFileDiagnostics(bundlePath: String, bundleIdentifier _: String?) -> Bool {
        !bundlePath.hasSuffix(".appex") && !bundlePath.contains(".appex/")
    }
    public static func flush() { sink.queue.sync {} }
    public static func stopFileLogging() { sink.stop() }

    private final class Sink: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.archalo.arckit.log", qos: .utility)
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock(); queue.sync {} }
        private var pending = 0
        private var dropped = 0
        private let system = Logger(subsystem: "com.archalo.arckit", category: "runtime")
        private let maximum = 8 * 1_024 * 1_024
        private var lastCleanup = Date.distantPast
        func append(_ message: String) {
            let safe = ArcKitLog.redact(String(message.prefix(8192)))
            guard ArcKitLog.shouldWriteFileDiagnostics(bundlePath: Bundle.main.bundleURL.path, bundleIdentifier: Bundle.main.bundleIdentifier) else {
                system.info("\(safe, privacy: .public)"); return
            }
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            guard pending < 512 else { dropped += 1; lock.unlock(); return }
            pending += 1
            let lost = dropped; dropped = 0
            lock.unlock()
            queue.async { [self] in
                defer { lock.lock(); pending -= 1; lock.unlock() }
                do {
                    try write(safe, dropped: lost)
                } catch { system.error("file log unavailable: \(error.localizedDescription, privacy: .private)") }
            }
        }
        private func write(_ message: String, dropped: Int) throws {
            let file = ArcKitLog.fileURL
            let fm = FileManager.default
            if Date().timeIntervalSince(lastCleanup) > 3600 {
                try ArcKitStoragePaths.secureDirectory(file.deletingLastPathComponent())
                for index in 0..<4 {
                    let path = index == 0 ? file : file.appendingPathExtension(String(index))
                    if let modified = try? path.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       Date().timeIntervalSince(modified) > 7 * 86400 { try fm.removeItem(at: path) }
                }
                lastCleanup = Date()
            }
            let values: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "component": ArcKitLog.component,
                "pid": ProcessInfo.processInfo.processIdentifier, "level": "info", "message": message, "dropped": dropped]
            var data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size + data.count > maximum {
                try? fm.removeItem(at: file.appendingPathExtension("3"))
                for index in stride(from: 2, through: 0, by: -1) {
                    let old = index == 0 ? file : file.appendingPathExtension(String(index))
                    if fm.fileExists(atPath: old.path) { try fm.moveItem(at: old, to: file.appendingPathExtension(String(index + 1))) }
                }
            }
            if !fm.fileExists(atPath: file.path) { guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } }
            try ArcKitStoragePaths.secureFile(file)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
    }
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(https?://[^\s?]+)\?[^\s]+"#, with: "$1?<redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|authorization|password|secret)[=:]\s*[^\s,}]+"#, with: "$1=<redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"(?:file://)?(?:/Users/|/Volumes/|/private/var/|/var/folders/)[^\n\r\"<>]*"#, with: "<path>", options: .regularExpression)
    }
}
