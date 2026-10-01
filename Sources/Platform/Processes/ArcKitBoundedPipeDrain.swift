import Foundation

public struct ArcKitPipeCapture: Sendable {
    public let data: Data
    public let exceededLimit: Bool
}

/// 持续排空子进程管道，避免先 waitUntilExit 导致管道写满死锁，同时限制保留在内存中的字节。
public final class ArcKitBoundedPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()
    private var exceededLimit = false
    private var started = false

    public init(pipe: Pipe, maximumBytes: Int = 8 * 1_024 * 1_024) {
        handle = pipe.fileHandleForReading
        self.maximumBytes = max(1, maximumBytes)
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        completion.enter()
        lock.unlock()

        Thread { [self] in
            defer { completion.leave() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    lock.lock()
                    let remaining = max(0, maximumBytes - captured.count)
                    if chunk.count > remaining {
                        exceededLimit = true
                    }
                    if remaining > 0 {
                        captured.append(contentsOf: chunk.prefix(remaining))
                    }
                    lock.unlock()
                }
            } catch {
                lock.lock()
                exceededLimit = true
                lock.unlock()
            }
        }.start()
    }

    public func waitForCapture() -> ArcKitPipeCapture {
        completion.wait()
        lock.lock()
        defer { lock.unlock() }
        return ArcKitPipeCapture(data: captured, exceededLimit: exceededLimit)
    }

    /// 子进程超时时主动打断阻塞读，避免孙进程持有 pipe 导致永不 EOF。
    public func cancel() {
        try? handle.close()
    }
}
