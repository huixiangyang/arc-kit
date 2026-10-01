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
            host.start()
            withExtendedLifetime((lock, host, app)) { RunLoop.main.run() }
        } catch {
            ArcKitLog.append("runtime host refused activation: \(error.localizedDescription)")
        }
    }
}
