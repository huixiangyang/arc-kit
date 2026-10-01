import ArcKitPlatform
import AppKit
import ArcKitApplication
import Darwin
import Foundation

@main
enum ArcKitMain {
    @MainActor
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--import-legacy-storage") {
            guard CommandLine.arguments.count == index + 3 else {
                print(L10n.string(.AppEntry.launchUsageArckitappImportLegacyStorageLegacyArc))
                Darwin.exit(2)
            }
            let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task.detached {
                do { try await LegacyStorageImport.run(source: source, destination: destination); print(L10n.string(.AppEntry.launchMigrationCompleteLegacyDataPreserved)); Darwin.exit(0) }
                catch { print(L10n.string(.AppEntry.launchMigrationFailed(String(describing: error.localizedDescription)))); Darwin.exit(1) }
            }
            dispatchMain()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--restore-storage") {
            guard CommandLine.arguments.count == index + 3 else {
                print(L10n.string(.AppEntry.launchRestoreUsage)); Darwin.exit(2)
            }
            let source = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            do { try StorageRecovery.run(source: source, destination: destination); print(L10n.string(.AppEntry.launchRestoreCompleteOriginalDatabasePreserved)); Darwin.exit(0) }
            catch { print(L10n.string(.AppEntry.launchRestoreFailed(String(describing: error.localizedDescription)))); Darwin.exit(1) }
        }
        // AppKit 事件循环必须从同步入口运行；嵌在 async main 的主队列任务里会饿死后续 MainActor 任务。
        // 窗口创建前完成存储准备；进入事件循环后，配置加载与保存仍由异步任务执行。
        do { try StorageBootstrap.prepare() }
        catch {
            showStorageFailure(error.localizedDescription)
            return
        }
        runApplication()
    }
    @MainActor private static func showStorageFailure(_ message: String) {
        let alert = NSAlert(); alert.messageText = L10n.string(.AppEntry.launchDataOpenFailed); alert.informativeText = message
        alert.addButton(withTitle: L10n.string(.AppEntry.launchQuit)); alert.runModal()
    }
    @MainActor private static func runApplication() {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-debug") {
            SettingsDebugSession.run()
            return
        }
        #endif
        // Arc Kit 的窗口由显式设置恢复，禁止 AppKit 启动时弹出崩溃恢复对话框并阻塞管理界面。
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        if CommandLine.arguments.contains(WindowManagementSmokeTestService.controllerArgument) {
            // 主 App 只负责图形会话与宿主窗口协调；真实 AX、Carbon 和权限必须由 Window Agent 证明。
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            Darwin.exit(WindowManagementSmokeTestService.runRemoteController())
        }
        let application = NSApplication.shared
        application.disableRelaunchOnLogin()
        let delegate = AppDelegate()
        application.delegate = delegate
        application.finishLaunching()
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

/// 传统 AppKit 入口：主 App 只负责设置、菜单栏与诊断；Finder 右键动作由独立 Agent 执行。
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 调试与视觉回归专用启动参数，确保测试可以绕过 LaunchServices 的 reopen 事件直接展示主窗口。
    private static let showMainWindowArgument = "--show-main-window"
    private var controller: AppController?
    /// AppController 初始化会切换激活策略，可能同步重入 open/reopen 回调；赋值完成前必须阻止第二次构造。
    private var isStartingController = false
    private var pendingInteractiveRequest = false
    private var isPreparingTermination = false

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start(launchMode: ArcKitApplicationLaunchPolicy.initialMode(
            hasExplicitShowWindowArgument: CommandLine.arguments.contains(Self.showMainWindowArgument)
        ))
    }

    func start(launchMode: ArcKitApplicationLaunchMode) {
        if let controller {
            if launchMode == .interactive {
                controller.showMainWindow()
            }
            return
        }
        if isStartingController {
            pendingInteractiveRequest = pendingInteractiveRequest || launchMode == .interactive
            return
        }
        isStartingController = true
        let createdController = AppController(launchMode: launchMode)
        controller = createdController
        isStartingController = false
        if pendingInteractiveRequest {
            pendingInteractiveRequest = false
            createdController.showMainWindow()
        }
    }

    @objc private func handleOpenApplicationEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        // macOS 会在登录项启动的 open-application 事件中携带该键。
        // 它是启动来源的唯一系统事实，不再使用一秒延时猜测用户意图。
        let launchedAsLoginItem = event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        start(launchMode: ArcKitApplicationLaunchPolicy.openApplicationMode(
            launchedAsLoginItem: launchedAsLoginItem
        ))
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        start(launchMode: .interactive)
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        start(launchMode: .interactive)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        start(launchMode: .interactive)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingTermination else { return .terminateLater }
        guard let controller else { return .terminateNow }
        isPreparingTermination = true
        Task { @MainActor in
            let canTerminate = await controller.prepareForTermination()
            isPreparingTermination = false
            sender.reply(toApplicationShouldTerminate: canTerminate)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // 仍声明安全解码契约；窗口本身禁用状态恢复，只保留受控的 frame autosave。
        true
    }

}
