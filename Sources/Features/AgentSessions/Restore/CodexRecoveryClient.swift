import ArcKitPlatform
import Darwin
import Foundation

/// 只在临时 CODEX_HOME 内重建原生索引；从不连接用户的运行实例，也不发送 turn/start。
final class CodexRecoveryClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var sequence = 0
    let workspace: URL

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"].map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    init(home: URL, executable: URL) throws {
        workspace = home.appendingPathComponent(".arckit-validation-workspace")
        try ArcKitStoragePaths.secureDirectory(workspace)
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio", "-c", "model_provider=\"arckit_backup\"", "-c", "model_providers.arckit_backup={name=\"Arc Kit offline validation\",base_url=\"http://127.0.0.1:9/v1\",wire_api=\"responses\",requires_openai_auth=false}", "-c", "analytics.enabled=false"]
        process.environment = ArcKitSubprocessEnvironment.sanitized(from: [:], overrides: ["HOME": home.path, "CODEX_HOME": home.path, "TMPDIR": home.path])
        process.currentDirectoryURL = workspace
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let result = try request("initialize", ["clientInfo": ["name": "arc-kit-session-recovery", "version": "1"], "capabilities": ["experimentalApi": true]])
            guard (result["userAgent"] as? String)?.contains("/0.163.0 ") == true else { throw AgentSessionError.nativeUnavailable }
        } catch { close(); throw error }
    }
    func request(_ method: String, _ parameters: [String: Any]) throws -> [String: Any] {
        sequence += 1
        var bytes = try JSONSerialization.data(withJSONObject: ["id": sequence, "method": method, "params": parameters]); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw AgentSessionError.unsupportedFormat }
                if (message["id"] as? Int) == sequence {
                    if let error = message["error"] as? [String: Any] { throw AgentSessionError.detail(error["message"] as? String ?? L10n.string(.AgentSessions.errorNative)) }
                    guard let result = message["result"] as? [String: Any] else { throw AgentSessionError.unsupportedFormat }
                    return result
                }
                continue
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&descriptor, 1, 100) > 0 {
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                guard count > 0 else { throw AgentSessionError.nativeUnavailable }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 64 * 1_024 * 1_024 else { throw AgentSessionError.invalidArchive }
            }
        }
        throw AgentSessionError.nativeUnavailable
    }
    func close() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { process.terminate() }
        let stop = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        if process.processIdentifier > 0 { process.waitUntilExit() }
        try? output.fileHandleForReading.close()
    }
    deinit { if process.isRunning { close() } }
}
