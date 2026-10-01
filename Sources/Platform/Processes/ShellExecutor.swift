import Darwin
import Foundation

public enum ShellExecutionCaptureResult: Equatable, Sendable {
    case completed(status: Int32, output: String)
    case timedOut
    case outputLimitExceeded
    case launchFailed(String)
}

/// 统一的 shell 命令执行工具，消除 FinderSync 和 SystemEnhancementService 中的重复 Process 代码。
public enum ShellExecutor {

    /// 执行固定可执行文件并有界捕获合并输出，供更新校验、卸载等需要退出码的事务使用。
    public static func runCapturingMergedOutput(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) -> ShellExecutionCaptureResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ArcKitSubprocessEnvironment.sanitized()
        process.standardOutput = pipe
        process.standardError = pipe
        let drain = ArcKitBoundedPipeDrain(pipe: pipe, maximumBytes: maximumBytes)
        do {
            try process.run()
            drain.start()
            try? pipe.fileHandleForWriting.close()
            let completed = waitForExit(process, timeout: timeout)
            if !completed { drain.cancel() }
            let capture = drain.waitForCapture()
            guard completed else { return .timedOut }
            guard !capture.exceededLimit else { return .outputLimitExceeded }
            return .completed(
                status: process.terminationStatus,
                output: String(data: capture.data, encoding: .utf8) ?? ""
            )
        } catch {
            return .launchFailed(error.localizedDescription)
        }
    }

    /// 直接运行固定可执行文件，参数不会经过 shell 展开。
    @discardableResult
    public static func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ArcKitSubprocessEnvironment.sanitized()
        process.standardError = errorPipe
        let errorDrain = ArcKitBoundedPipeDrain(pipe: errorPipe, maximumBytes: 64 * 1_024)
        do {
            try process.run()
            errorDrain.start()
            try? errorPipe.fileHandleForWriting.close()
            let completed = waitForExit(process, timeout: timeout)
            if !completed { errorDrain.cancel() }
            let errorCapture = errorDrain.waitForCapture()
            guard completed else {
                ArcKitLog.append(
                    "process timed out timeout=\(timeout) executable=\(executableURL.path) arguments=\(arguments)"
                )
                return false
            }
            let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
            if !succeeded {
                logProcessFailure(
                    executableURL: executableURL,
                    arguments: arguments,
                    status: process.terminationStatus,
                    errorCapture: errorCapture
                )
            }
            return succeeded
        } catch {
            ArcKitLog.append(
                "process launch failed executable=\(executableURL.path) arguments=\(arguments) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    public static func run(_ command: String, timeout: TimeInterval) -> Bool {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ArcKitSubprocessEnvironment.sanitized()
        process.standardError = errorPipe
        let errorDrain = ArcKitBoundedPipeDrain(pipe: errorPipe, maximumBytes: 64 * 1_024)
        do {
            try process.run()
            errorDrain.start()
            try? errorPipe.fileHandleForWriting.close()
            let completed = waitForExit(process, timeout: timeout)
            if !completed { errorDrain.cancel() }
            let errorCapture = errorDrain.waitForCapture()
            guard completed else {
                ArcKitLog.append("shell command timed out timeout=\(timeout) command=\(command)")
                return false
            }
            let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
            if !succeeded {
                logFailure(command: command, status: process.terminationStatus, errorCapture: errorCapture)
            }
            return succeeded
        } catch {
            ArcKitLog.append("shell command launch failed command=\(command) error=\(error.localizedDescription)")
            return false
        }
    }

    public static func runWithOutput(
        _ command: String,
        timeout: TimeInterval,
        logsFailure: Bool = true
    ) -> String? {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ArcKitSubprocessEnvironment.sanitized()
        process.standardOutput = pipe
        process.standardError = errorPipe
        let outputDrain = ArcKitBoundedPipeDrain(pipe: pipe)
        let errorDrain = ArcKitBoundedPipeDrain(pipe: errorPipe, maximumBytes: 64 * 1_024)
        do {
            try process.run()
            outputDrain.start()
            errorDrain.start()
            try? pipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            let completed = waitForExit(process, timeout: timeout)
            if !completed {
                outputDrain.cancel()
                errorDrain.cancel()
            }
            let outputCapture = outputDrain.waitForCapture()
            let errorCapture = errorDrain.waitForCapture()
            guard completed else {
                ArcKitLog.append("shell command output timed out timeout=\(timeout) command=\(command)")
                return nil
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                if logsFailure {
                    logFailure(command: command, status: process.terminationStatus, errorCapture: errorCapture)
                }
                return nil
            }
            guard !outputCapture.exceededLimit else {
                ArcKitLog.append("shell command output exceeded 8 MiB command=\(command)")
                return nil
            }
            return String(data: outputCapture.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            ArcKitLog.append("shell command output launch failed command=\(command) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func logFailure(
        command: String,
        status: Int32,
        errorCapture: ArcKitPipeCapture
    ) {
        let stderr = String(data: errorCapture.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ArcKitLog.append(
            "shell command failed status=\(status) command=\(command) " +
                "stderr=\(stderr.isEmpty ? "-" : stderr) truncated=\(errorCapture.exceededLimit)"
        )
    }

    /// 所有子进程都必须有有界退出；普通 terminate 无效后升级 SIGKILL。
    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0.05, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }

        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return false
    }

    private static func logProcessFailure(
        executableURL: URL,
        arguments: [String],
        status: Int32,
        errorCapture: ArcKitPipeCapture
    ) {
        let stderr = String(data: errorCapture.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ArcKitLog.append(
            "process failed status=\(status) executable=\(executableURL.path) arguments=\(arguments) " +
                "stderr=\(stderr.isEmpty ? "-" : stderr) truncated=\(errorCapture.exceededLimit)"
        )
    }
}
