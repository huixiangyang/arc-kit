import ArcKitFinder
import ArcKitPlatform
import Darwin
import Foundation

/// Finder Agent 只负责调度。每个真实文件动作都由一次性子进程执行，
/// 子进程崩溃、卡死或返回损坏数据都只会完成当前请求的失败回调。
public final class FinderOperationWorkerClient: @unchecked Sendable {
    public typealias Completion = @MainActor @Sendable (
        Result<FinderCommandExecutionResult?, FinderOperationWorkerError>
    ) -> Void

    private let executableURL: URL?
    private let timeout: TimeInterval
    private let environmentOverrides: [String: String]
    @MainActor private static var hasActiveWorker = false

    public init(
        executableURL: URL? = Bundle.main.executableURL,
        timeout: TimeInterval = 120,
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.timeout = max(1, timeout)
        self.environmentOverrides = environmentOverrides
    }

    @MainActor public func execute(
        _ command: FinderCommandRequest,
        settings: FinderRuntimeSettings,
        completion: @escaping Completion
    ) {
        // 所有客户端共用一个执行名额，不排队保存含完整配置的请求，也不并发修改文件。
        guard !Self.hasActiveWorker else {
            completion(.failure(.busy))
            return
        }
        Self.hasActiveWorker = true
        let request = FinderOperationWorkerRequest(
            command: command,
            settings: settings,
            timeout: timeout
        )
        let executableURL = executableURL
        let timeout = timeout
        let environmentOverrides = environmentOverrides
        Task.detached(priority: .userInitiated) {
            let result = Self.run(
                request,
                executableURL: executableURL,
                timeout: timeout,
                environmentOverrides: environmentOverrides
            )
            await MainActor.run {
                Self.hasActiveWorker = false
                completion(result)
            }
        }
    }

    private static func run(
        _ request: FinderOperationWorkerRequest,
        executableURL: URL?,
        timeout: TimeInterval,
        environmentOverrides: [String: String]
    ) -> Result<FinderCommandExecutionResult?, FinderOperationWorkerError> {
        guard let executableURL else { return .failure(.executableUnavailable) }
        let input: Data
        do {
            input = try FinderOperationWorkerCodec.encode(request)
            guard input.count <= FinderOperationWorkerCodec.maximumPayloadBytes else {
                return .failure(.requestTooLarge)
            }
        } catch {
            return .failure(.launchFailed(L10n.string(.FinderActions.workerConnectionEncodeFailed(String(describing: error.localizedDescription)))))
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--operation-worker"]
        process.environment = ArcKitSubprocessEnvironment.sanitized(overrides: environmentOverrides)
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let outputDrain = FinderWorkerPipeDrain(handle: standardOutput.fileHandleForReading)
        let errorDrain = FinderWorkerPipeDrain(handle: standardError.fileHandleForReading)

        var didLaunch = false
        do {
            try process.run()
            didLaunch = true
            outputDrain.start()
            errorDrain.start()
            // 父进程不持有子进程管道的另一端，确保子进程退出后 drain 能立即读到 EOF。
            try? standardInput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try standardInput.fileHandleForWriting.write(contentsOf: input)
            try standardInput.fileHandleForWriting.close()
        } catch {
            try? standardInput.fileHandleForWriting.close()
            if didLaunch {
                terminate(process)
                process.waitUntilExit()
            }
            outputDrain.wait()
            errorDrain.wait()
            return .failure(.launchFailed(error.localizedDescription))
        }

        let expiresAt = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < expiresAt {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            terminate(process)
        }
        process.waitUntilExit()
        let outputClosed = outputDrain.wait()
        let errorClosed = errorDrain.wait()

        if timedOut { return .failure(.timedOut) }
        if !outputClosed || !errorClosed { return .failure(.outputDidNotClose) }
        if outputDrain.exceededLimit { return .failure(.responseTooLarge) }
        guard process.terminationReason == .exit, process.terminationStatus == EXIT_SUCCESS else {
            let detail = errorDrain.text.isEmpty ? L10n.string(.FinderActions.workerConnectionErrorOutputProvidedMissing) : errorDrain.text
            return .failure(.crashed(status: process.terminationStatus, detail: detail))
        }

        do {
            let reply = try FinderOperationWorkerCodec.decode(
                FinderOperationWorkerReply.self,
                from: outputDrain.data
            )
            try reply.validate(expectedRequestID: request.requestID)
            return .success(reply.result)
        } catch let error as FinderOperationWorkerError {
            return .failure(error)
        } catch {
            return .failure(.malformedReply)
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let forceKillAt = Date().addingTimeInterval(1)
        while process.isRunning, Date() < forceKillAt {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class FinderWorkerPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var storedData = Data()
    private var didExceedLimit = false
    private var cancelled = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                group.leave()
            }
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                lock.withFinderWorkerLock { didExceedLimit = true }
                return
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            // 孙进程可能继承 stdout；用可取消的非阻塞读取，不能无限等 EOF 或跨线程 close。
            while !lock.withFinderWorkerLock({ cancelled }) {
                var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptorPoll, 1, 50)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else {
                    lock.withFinderWorkerLock { didExceedLimit = true }
                    return
                }
                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { return }
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else {
                    lock.withFinderWorkerLock { didExceedLimit = true }
                    return
                }
                lock.withFinderWorkerLock {
                    let remaining = max(0, FinderOperationWorkerCodec.maximumPayloadBytes - storedData.count)
                    storedData.append(contentsOf: buffer.prefix(min(count, remaining)))
                    if count > remaining { didExceedLimit = true }
                }
            }
        }
    }

    @discardableResult
    func wait(timeout: TimeInterval = 1) -> Bool {
        if group.wait(timeout: .now() + timeout) == .success { return true }
        lock.withFinderWorkerLock { cancelled = true }
        group.wait()
        return false
    }

    var data: Data {
        lock.withFinderWorkerLock { storedData }
    }

    var text: String {
        let decoded = String(decoding: data.prefix(2_048), as: UTF8.self)
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var exceededLimit: Bool {
        lock.withFinderWorkerLock { didExceedLimit }
    }
}

private extension NSLock {
    func withFinderWorkerLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
