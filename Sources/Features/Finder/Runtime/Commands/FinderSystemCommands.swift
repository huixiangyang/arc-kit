import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation

/// 固定系统工具与参数分离，文件名不参与 shell 解析。
struct FinderProcessRunner {
    private let execute: (URL, [String]) -> Bool

    init(execute: @escaping (URL, [String]) -> Bool = {
        ShellExecutor.run(executableURL: $0, arguments: $1, timeout: 110)
    }) {
        self.execute = execute
    }

    func run(executable: String, arguments: [String]) throws {
        guard execute(URL(fileURLWithPath: executable), arguments) else {
            throw FinderCommandExecutionError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)
        }
    }
}

/// Worker 必须等 Launch Services 回调后才能退出；发出异步打开请求不代表打开成功。
struct FinderApplicationOpener {
    typealias Completion = @Sendable (String?) -> Void
    typealias Open = @Sendable ([URL], URL?, @escaping Completion) -> Void
    private let workspaceOpen: Open
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30, open: Open? = nil) {
        self.timeout = timeout
        workspaceOpen = open ?? Self.defaultWorkspaceOpen
    }

    func openURLs(_ urls: [URL], applicationURL: URL?, label: String) throws {
        guard !urls.isEmpty else { throw FinderCommandExecutionError.emptySelection }
        let deadline = DispatchTime.now() + timeout
        // 指定应用支持整批打开；默认处理器 API 每次只接收一个 URL。
        let batches = applicationURL == nil ? urls.map { [$0] } : [urls]
        for batch in batches {
            let reply = OpenReply()
            workspaceOpen(batch, applicationURL) { reply.finish(error: $0) }
            guard reply.ready.wait(timeout: deadline) == .success else {
                throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.systemResultUnconfirmed(String(describing: label))))
            }
            if let error = reply.error {
                throw FinderCommandExecutionError.commandFailed("\(label)：\(error)")
            }
        }
    }

    private static func defaultWorkspaceOpen(urls: [URL], applicationURL: URL?, completion: @escaping Completion) {
        let configuration = NSWorkspace.OpenConfiguration()
        // AppKit 头文件明确 completion 在并发队列执行，Worker 可有界等待，不阻塞 Host。
        let handler: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { app, error in
            completion(error?.localizedDescription ?? (app == nil ? L10n.string(.FinderActions.systemSystemReturnedTargetAppMissing) : nil))
        }
        if let applicationURL {
            NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration, completionHandler: handler)
        } else if let url = urls.first {
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: handler)
        } else {
            completion(L10n.string(.FinderActions.systemItemsOpenMissing))
        }
    }

    private final class OpenReply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var finished = false
        private var storedError: String?

        var error: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func finish(error: String?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            storedError = error
            lock.unlock()
            ready.signal()
        }
    }
}
