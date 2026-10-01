import Darwin
import Foundation

@_silgen_name("flock")
private func arcKitSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public enum ArcKitProcessKind: String, Sendable {
    case app
    case host
    case worker
}

/// Host 与 Worker 共用的进程级排他锁，必须在创建 XPC、AX 或 EventTap 运行时之前取得。
public final class ArcKitProcessLock: @unchecked Sendable {
    private var fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    public static func defaultLockPath(for kind: ArcKitProcessKind) -> String {
        ArcKitStoragePaths.current.lock(kind).path
    }

    public static func acquire(
        for kind: ArcKitProcessKind,
        lockPath: String? = nil
    ) -> ArcKitProcessLock? {
        let resolvedPath = lockPath ?? defaultLockPath(for: kind)
        do { try ArcKitStoragePaths.secureDirectory(URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()) } catch { return nil }
        let descriptor = Darwin.open(
            resolvedPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            ArcKitLog.append(
                "\(kind.rawValue) agent single instance lock open failed " +
                    "path=\(resolvedPath) errno=\(errno)"
            )
            return nil
        }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == Darwin.getuid()
        else {
            Darwin.close(descriptor)
            ArcKitLog.append(
                "\(kind.rawValue) agent single instance lock rejected non-owned regular file"
            )
            return nil
        }
        guard arcKitSystemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        // 文件内容只用于人工诊断；真正互斥由内核随文件描述符生命周期持有。
        _ = Darwin.ftruncate(descriptor, 0)
        let processText = "\(ProcessInfo.processInfo.processIdentifier)\n"
        processText.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, strlen(pointer))
        }
        return ArcKitProcessLock(fileDescriptor: descriptor)
    }

    public func release() {
        guard fileDescriptor >= 0 else { return }
        _ = arcKitSystemFlock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}
