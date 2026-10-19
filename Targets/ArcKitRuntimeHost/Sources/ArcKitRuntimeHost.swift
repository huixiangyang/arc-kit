import AppKit
import ArcKitPlatform
import ArcKitFinderRuntime
import Darwin

@main
enum ArcKitRuntimeHostMain {
    @MainActor static func main() {
        ArcKitSubprocessEnvironment.scrubSensitiveVariablesFromCurrentProcess()
        if CommandLine.arguments.dropFirst().first == "--operation-worker" {
            exit(FinderOperationWorkerEntrypoint.run())
        }
        guard let lock = ArcKitProcessLock.acquire(for: .host) else { return }
        do {
            let session = try RuntimeHostSession.load()
            try ArcKitXPCPeerIdentityVerifier.verifyProcess(session.processID,
                expectedBundleURL: URL(fileURLWithPath: ArcKitConstants.installedAppPath),
                expectedBundleIdentifier: ArcKitConstants.appBundleIdentifier)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let host = RuntimeHost(session: session)
            let delegate = RuntimeHostAppDelegate(host: host)
            app.delegate = delegate
            // NSScreen 的刷新依赖 AppKit 派发窗口服务器事件，普通 RunLoop 不会消费这些事件。
            withExtendedLifetime((lock, host, delegate)) { app.run() }
        } catch {
            ArcKitLog.append("runtime host refused activation: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class RuntimeHostAppDelegate: NSObject, NSApplicationDelegate {
    private let host: RuntimeHost

    init(host: RuntimeHost) { self.host = host }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logScreens(reason: "launch")
        host.start()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        logScreens(reason: "changed")
    }

    private func logScreens(reason: String) {
        let screens = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return "id=\(id) frame=\(screen.frame) visible=\(screen.visibleFrame) cg=\(CGDisplayBounds(id))"
        }.joined(separator: "; ")
        ArcKitLog.append("runtime screens reason=\(reason) \(screens)")
    }
}
