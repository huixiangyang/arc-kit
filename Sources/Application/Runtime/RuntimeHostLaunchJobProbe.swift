import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Darwin
import Foundation

/// `SMAppService.status` 只描述后台项目的授权状态；这里单独核对当前用户域中的实际 launchd 运行态。
enum RuntimeHostLaunchJobProbe {
    static func isRunning() -> Bool {
        let label = ArcKitConstants.runtimeHostLaunchAgentIdentifier
        let domainTarget = "gui/\(getuid())/\(label)"
        let runningPID: Int32? = switch ShellExecutor.runCapturingMergedOutput(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print", domainTarget],
            timeout: 2,
            maximumBytes: 256 * 1_024
        ) {
        case let .completed(status, output) where status == 0:
            runningPID(fromLaunchctlPrint: output)
        case .completed, .timedOut, .outputLimitExceeded, .launchFailed:
            nil
        }
        guard let runningPID else { return false }
        return kill(pid_t(runningPID), 0) == 0 || errno == EPERM
    }

    static func waitUntilStopped(label: String = ArcKitConstants.runtimeHostLaunchAgentIdentifier, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            let result = ShellExecutor.runCapturingMergedOutput(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", "gui/\(getuid())/\(label)"],
                timeout: 2, maximumBytes: 256 * 1_024
            )
            // 等待态作业仍能由 Mach service 唤醒；只有明确不存在才算停止，查询失败不能冒充成功。
            if confirmsJobRemoval(result, label: label) { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
    }

    static func confirmsJobRemoval(_ result: ShellExecutionCaptureResult, label: String) -> Bool {
        guard case let .completed(status, output) = result, status != 0 else { return false }
        return output.contains("Could not find service \"\(label)\"")
    }

    /// 只解析 launchctl 作业自身的一层字段，不能把 coalition 内嵌的 `state = active` 当成进程健康。
    nonisolated static func runningPID(fromLaunchctlPrint output: String) -> Int32? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0 == "\tstate = running" }),
              !lines.contains(where: { $0 == "\tjob state = spawn failed" }),
              let pidLine = lines.first(where: { $0.hasPrefix("\tpid = ") })
        else {
            return nil
        }
        let rawPID = pidLine.dropFirst("\tpid = ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(rawPID), pid > 0 else { return nil }
        return pid
    }
}
