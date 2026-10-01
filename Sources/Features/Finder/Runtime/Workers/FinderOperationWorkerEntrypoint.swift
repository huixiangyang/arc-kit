import ArcKitFinder
import ArcKitPlatform
import Darwin
import Foundation

/// 与 Finder Agent 复用同一可执行文件的单次 Worker 入口；该路径不启动 Mach service。
public enum FinderOperationWorkerEntrypoint {
    @MainActor
    public static func run() -> Int32 {
        guard let workerLock = ArcKitProcessLock.acquire(for: .worker) else { return EXIT_FAILURE }
        defer { withExtendedLifetime(workerLock) {} }
        // Worker 自成进程组，超时/父宿主消失时连同其拥有的 shell 子进程一起回收。
        guard setpgid(0, 0) == 0 else { return EXIT_FAILURE }
        let workerGroup = getpid()
        defer { reapOwnedChildren(in: workerGroup) }
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        termination.setEventHandler { kill(-workerGroup, SIGKILL) }
        termination.resume()
        defer { termination.cancel() }
        // 父 Agent 被强制结束时，Worker 不能变成失去超时管理的孤儿进程。
        let parentPID = getppid()
        guard parentPID > 1 else { return EXIT_FAILURE }
        let parentMonitor = DispatchSource.makeProcessSource(
            identifier: parentPID, eventMask: .exit, queue: .global(qos: .utility)
        )
        parentMonitor.setEventHandler { kill(-workerGroup, SIGKILL) }
        parentMonitor.resume()
        guard getppid() == parentPID else { return EXIT_FAILURE }
        defer { parentMonitor.cancel() }
        // 输入读取及动作执行都受自身硬时限约束，即使父进程失去响应也会回收。
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + 120)
        deadline.setEventHandler { kill(-workerGroup, SIGKILL) }
        deadline.resume()
        defer { deadline.cancel() }
        let input: Data
        do {
            input = try readBoundedInput()
        } catch {
            fputs(L10n.string(.FinderActions.workerInputRejected), stderr)
            return EXIT_FAILURE
        }
        var requestID = UUID()
        let reply: FinderOperationWorkerReply

        do {
            let request = try FinderOperationWorkerCodec.decode(
                FinderOperationWorkerRequest.self,
                from: input
            )
            requestID = request.requestID
            L10n.configure(request.language)
            try request.validate()

#if DEBUG
            // 仅供故障注入验证；Release 不编译此分支。
            switch ProcessInfo.processInfo.environment["ARC_KIT_FINDER_WORKER_FAULT"] {
            case "crash":
                raise(SIGABRT)
                Darwin._exit(EXIT_FAILURE)
            case "hang":
                while true { RunLoop.current.run(until: Date().addingTimeInterval(60)) }
            default:
                break
            }
#endif

            let dispatcher = FinderCommandDispatcher(
                files: FinderFileCommandExecutor(batchRenameRuleProvider: { sourcePaths in
                    FinderBatchRenamePrompt.present(sourcePaths: sourcePaths)
                }),
                images: FinderImageCommandExecutor(folderIconImagePicker: {
                    FinderFolderIconPrompt.present()
                })
            )
            let result = try dispatcher.execute(request.command, settings: request.settings)
            reply = FinderOperationWorkerReply(requestID: requestID, result: result)
        } catch {
            reply = FinderOperationWorkerReply(
                requestID: requestID,
                errorMessage: error.localizedDescription
            )
        }

        do {
            let output = try FinderOperationWorkerCodec.encode(reply)
            guard output.count <= FinderOperationWorkerCodec.maximumPayloadBytes else {
                return EXIT_FAILURE
            }
            try FileHandle.standardOutput.write(contentsOf: output)
            return EXIT_SUCCESS
        } catch {
            return EXIT_FAILURE
        }
    }

    private static func reapOwnedChildren(in group: pid_t) {
        // 正常返回也清理 shell 留下的同组后台子孙，显式打开的用户应用不属于此进程组。
        let byteCount = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard byteCount > 0 else { return }
        var members = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 32)
        let capacity = Int32(members.count * MemoryLayout<pid_t>.size)
        let actual = members.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, capacity) }
        for pid in members.prefix(max(0, Int(actual)) / MemoryLayout<pid_t>.size) where pid > 1 && pid != group {
            if getpgid(pid) == group { kill(pid, SIGKILL) }
        }
    }

    private static func readBoundedInput() throws -> Data {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            guard input.count <= FinderOperationWorkerCodec.maximumPayloadBytes - chunk.count else {
                throw FinderOperationWorkerError.requestTooLarge
            }
            input.append(chunk)
        }
        return input
    }
}
