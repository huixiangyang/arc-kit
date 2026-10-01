import ArcKitPlatform
import ArcKitWindow
import ApplicationServices
@preconcurrency import AppKit
import Foundation

public struct WindowManagementSmokeActionReport: Codable, Sendable {
    public var action: String
    public var succeeded: Bool
    public var userMessage: String?
    public var diagnostics: [String: String]
}

public struct WindowManagementEntryPointSmokeReport: Codable, Sendable {
    public var entryPoint: String
    public var action: String
    public var succeeded: Bool
    public var userMessage: String?
    public var diagnostics: [String: String]
}

public struct WindowManagementSmokeReport: Codable, Sendable {
    public var checkedAt: String
    public var accessibilityTrusted: Bool
    public var accessibilityOperational: Bool
    public var screenLocked: Bool
    public var targetBundleIdentifier: String
    public var targetProcessIdentifier: Int32?
    public var screenCount: Int
    public var skippedActions: [String]
    public var actions: [WindowManagementSmokeActionReport]
    public var entryPoints: [WindowManagementEntryPointSmokeReport]
}

enum WindowSmokeSessionState {
    static let screenLockedKey = "CGSSessionScreenIsLocked"

    static func isScreenLocked(in session: [String: Any]?) -> Bool {
        guard let value = session?[screenLockedKey] else { return false }
        if let locked = value as? Bool { return locked }
        if let locked = value as? NSNumber { return locked.boolValue }
        return false
    }

    static var isScreenLocked: Bool {
        isScreenLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}

/// NSWorkspace completion 可能从任意队列返回，用锁封装结果，避免并发闭包修改局部变量。
private final class WorkspaceLaunchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var applicationStorage: NSRunningApplication?
    private var errorStorage: Error?
    private var completedStorage = false

    func complete(application: NSRunningApplication?, error: Error?) {
        lock.lock()
        applicationStorage = application
        errorStorage = error
        completedStorage = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completedStorage
    }

    var result: (application: NSRunningApplication?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (applicationStorage, errorStorage)
    }
}

/// 主 App 提供图形会话协调，正式 AX/Carbon 证据通过安全 XPC 绑定已安装 Runtime Host 身份。
/// 旧 CLI/主进程 AX Controller 已删除；唯一入口是 `runRemoteController`。
@MainActor
public enum WindowManagementSmokeTestService {
    public static let controllerArgument = "--arckit-window-smoke-controller"
    public static let reportURL = ArcKitStoragePaths.current.diagnostics.appendingPathComponent("window-smoke.json")
    public static let markdownReportURL = ArcKitStoragePaths.current.diagnostics.appendingPathComponent("window-smoke.md")

    private static let targetBundleIdentifier = "com.apple.TextEdit"

    /// 正式安装态从主 App 发起，但所有 AX、Carbon 与窗口写入都由已获授权的 Runtime Host 执行。
    public static func runRemoteController() -> Int32 {
        let client = WindowAgentXPCClient()
        let screenLocked = WindowSmokeSessionState.isScreenLocked
        var latestState: WindowAgentRuntimeSnapshot?

        do {
            latestState = try sendRemote(
                WindowAgentRequest(operation: .fetchState, timeout: 3),
                using: client
            ).state
            guard let initialState = latestState else {
                throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestHostReturnedRuntimeStateMissing))
            }
            guard !screenLocked else {
                let message = L10n.string(.WindowSettings.smokeTestDesktopLockedUnlockMac)
                writeRemoteFailureReport(
                    state: initialState,
                    screenLocked: true,
                    message: message,
                    action: "setup"
                )
                fputs(L10n.string(.WindowSettings.smokeTestArcKitWindowSmokeTestSkipped(String(describing: message))), stderr)
                return 3
            }
            guard initialState.accessibilityTrusted, initialState.accessibilityOperational else {
                writeRemoteFailureReport(
                    state: initialState,
                    screenLocked: false,
                    message: L10n.string(.WindowSettings.smokeTestHostLacksAccessibility),
                    action: "setup"
                )
                fputs(L10n.string(.WindowSettings.smokeTestArcKitWindowSmokeTestSkippedRuntime), stderr)
                return 2
            }

            guard initialState.lifecycle == .running else {
                throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestEnableWindowManagementMainApp))
            }

            let smokeSettings = try SettingsRepository().load().windowManagement
            let appliedState = initialState
            let host = try launchIsolatedHost()
            defer {
                host.application.forceTerminate()
                try? FileManager.default.removeItem(at: host.cleanupURL)
            }
            try activateAndWaitForFrontmost(host.application)
            _ = try sendRemote(
                WindowAgentRequest(operation: .captureTarget, timeout: 3),
                using: client
            )

            var actions = WindowLayoutAction.allCases.filter {
                $0 != .fullScreen && $0 != .nextDisplay && $0 != .previousDisplay && $0 != .restore
            }
            var skippedActions: [String] = []
            if NSScreen.screens.count > 1 {
                actions.append(contentsOf: [.nextDisplay, .previousDisplay])
            } else {
                skippedActions = [WindowLayoutAction.nextDisplay.rawValue, WindowLayoutAction.previousDisplay.rawValue]
            }
            actions.append(.restore)

            var actionReports = actions.map { action -> WindowManagementSmokeActionReport in
                do {
                    let result = try performRemote(action, using: client)
                    return WindowManagementSmokeActionReport(
                        action: action.rawValue,
                        succeeded: result.succeeded,
                        userMessage: result.userMessage,
                        diagnostics: result.diagnosticFields
                    )
                } catch {
                    return WindowManagementSmokeActionReport(
                        action: action.rawValue,
                        succeeded: false,
                        userMessage: error.localizedDescription,
                        diagnostics: [:]
                    )
                }
            }
            actionReports.append(runRemoteFullScreenSmoke(using: client))
            let entryPointReports = runRemoteResidentGlobalHotKeySmokes(
                client: client,
                settings: smokeSettings,
                state: appliedState,
                application: host.application
            )
            let report = WindowManagementSmokeReport(
                checkedAt: ISO8601DateFormatter().string(from: Date()),
                accessibilityTrusted: appliedState.accessibilityTrusted,
                accessibilityOperational: appliedState.accessibilityOperational,
                screenLocked: false,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessIdentifier: Int32(host.application.processIdentifier),
                screenCount: NSScreen.screens.count,
                skippedActions: skippedActions,
                actions: actionReports,
                entryPoints: entryPointReports
            )
            writeReport(report)

            let failedActions = actionReports.filter { !$0.succeeded }.map(\.action)
            let failedEntryPoints = entryPointReports.filter { !$0.succeeded }.map(\.action)
            guard failedActions.isEmpty, failedEntryPoints.isEmpty else {
                let failures = failedActions + failedEntryPoints
                fputs(L10n.string(.WindowSettings.smokeTestArcKitHostSmokeTestFailed(String(describing: failures.joined(separator: ", ")))), stderr)
                return 1
            }
            print(L10n.string(.WindowSettings.smokeTestArcKitHostSmokeTestPassed(String(describing: actionReports.count), String(describing: entryPointReports.count))))
            return 0
        } catch {
            let fallbackState = latestState ?? WindowAgentRuntimeSnapshot(
                lifecycle: .unavailable,
                processID: 0,
                launchID: UUID(),
                accessibilityTrusted: false,
                accessibilityOperational: false
            )
            writeRemoteFailureReport(
                state: fallbackState,
                screenLocked: screenLocked,
                message: error.localizedDescription,
                action: "setup"
            )
            fputs(L10n.string(.WindowSettings.smokeTestHostLaunchFailed(String(describing: error.localizedDescription))), stderr)
            return fallbackState.accessibilityTrusted && fallbackState.accessibilityOperational ? 1 : 2
        }
    }

    private static func sendRemote(
        _ request: WindowAgentRequest,
        using client: WindowAgentXPCClient
    ) throws -> WindowAgentReply {
        var outcome: Result<WindowAgentReply, RuntimeAgentIPCError>?
        let session = try RuntimeHostSession.load()
        var request = request
        request.sessionID = session.id
        request.revision = session.revision
        client.send(request) { result in
            outcome = result
        }
        try waitUntil(
            timeout: max(0.2, request.deadline.timeIntervalSinceNow + 0.5),
            message: L10n.string(.WindowSettings.smokeTestTimeoutWaitingHost(String(describing: request.operation.rawValue)))
        ) {
            pumpApplicationEvents(for: 0.01)
            return outcome != nil
        }
        guard let outcome else {
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestResponseHostMissing(String(describing: request.operation.rawValue))))
        }
        switch outcome {
        case let .success(reply):
            return reply
        case let .failure(error):
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestHostRequestFailed(String(describing: error.localizedDescription))))
        }
    }

    private static func performRemote(
        _ action: WindowLayoutAction,
        using client: WindowAgentXPCClient
    ) throws -> WindowManagementResult {
        let reply = try sendRemote(
            WindowAgentRequest(
                operation: .performAction,
                timeout: action == .fullScreen ? 6 : 3,
                action: action
            ),
            using: client
        )
        guard let result = reply.result else {
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestHostReturnedActionResultMissing(String(describing: action.rawValue))))
        }
        return result
    }

    private static func runRemoteFullScreenSmoke(
        using client: WindowAgentXPCClient
    ) -> WindowManagementSmokeActionReport {
        do {
            let enter = try performRemote(.fullScreen, using: client)
            guard enter.succeeded, enter.diagnosticFields["fullScreenAfter"] == "true" else {
                return WindowManagementSmokeActionReport(
                    action: WindowLayoutAction.fullScreen.rawValue,
                    succeeded: false,
                    userMessage: enter.userMessage ?? L10n.string(.WindowSettings.smokeTestFullScreenEnterFailed),
                    diagnostics: enter.diagnosticFields
                )
            }
            let exit = try performRemote(.fullScreen, using: client)
            let exited = exit.succeeded && exit.diagnosticFields["fullScreenAfter"] == "false"
            var diagnostics = enter.diagnosticFields
            diagnostics["entered"] = "true"
            diagnostics["exited"] = exited ? "true" : "false"
            diagnostics["executor"] = "window-agent-xpc"
            return WindowManagementSmokeActionReport(
                action: WindowLayoutAction.fullScreen.rawValue,
                succeeded: exited,
                userMessage: exited ? nil : (exit.userMessage ?? L10n.string(.WindowSettings.smokeTestFullScreenExitFailed)),
                diagnostics: diagnostics
            )
        } catch {
            return WindowManagementSmokeActionReport(
                action: WindowLayoutAction.fullScreen.rawValue,
                succeeded: false,
                userMessage: error.localizedDescription,
                diagnostics: ["executor": "window-agent-xpc"]
            )
        }
    }

    private static func runRemoteResidentGlobalHotKeySmokes(
        client: WindowAgentXPCClient,
        settings: WindowManagementSettings,
        state: WindowAgentRuntimeSnapshot,
        application: NSRunningApplication
    ) -> [WindowManagementEntryPointSmokeReport] {
        let entryPoint = "residentGlobalHotKey"
        let actions: [WindowLayoutAction] = [.topLeft, .restore]
        do {
            guard state.processID > 0,
                  state.hotKeyRegisteredCount > 0,
                  state.hotKeyFailedBindings.isEmpty,
                  !state.hotKeyHandlerInstallationFailed
            else {
                throw WindowManagementSmokeFailure(
                    L10n.string(.WindowSettings.smokeTestResidentHostShortcutsNotReadyPid(String(describing: state.processID))) +
                    "registered=\(state.hotKeyRegisteredCount) failed=\(state.hotKeyFailedBindings.count)"
                )
            }
            guard let layoutBinding = settings.binding(for: .topLeft), layoutBinding.isSafeGlobalShortcut,
                  let restoreBinding = settings.binding(for: .restore), restoreBinding.isSafeGlobalShortcut
            else {
                throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestSmokeTestSettingsLackExecutableTopLeft))
            }

            try activateAndWaitForFrontmost(application)
            _ = try sendRemote(
                WindowAgentRequest(operation: .captureTarget, timeout: 3),
                using: client
            )
            _ = try performRemote(.center, using: client)

            let layoutReport = try runRemoteHotKey(
                action: .topLeft,
                binding: layoutBinding,
                processID: state.processID,
                launchID: state.launchID,
                client: client
            )
            let restoreReport = try runRemoteHotKey(
                action: .restore,
                binding: restoreBinding,
                processID: state.processID,
                launchID: state.launchID,
                client: client
            )
            return [layoutReport, restoreReport]
        } catch {
            return actions.map {
                entryPointFailure(entryPoint, action: $0, message: error.localizedDescription)
            }
        }
    }

    private static func runRemoteHotKey(
        action: WindowLayoutAction,
        binding: WindowHotKeyBinding,
        processID: Int32,
        launchID: UUID,
        client: WindowAgentXPCClient
    ) throws -> WindowManagementEntryPointSmokeReport {
        let diagnosticOffset = diagnosticLogSize()
        try postHotKey(binding)
        let result = try waitForRemoteAction(
            action,
            processID: processID,
            client: client,
            timeout: 7
        )
        let evidence = try waitForResidentHotKeyDiagnostics(
            processID: processID,
            action: action,
            startingAt: diagnosticOffset,
            timeout: 2
        )
        var diagnostics = result.diagnosticFields
        diagnostics["residentPID"] = String(processID)
        diagnostics["agentLaunchID"] = launchID.uuidString
        diagnostics["shortcut"] = binding.displayShortcut
        diagnostics["callbackEvidence"] = evidence.callback
        diagnostics["actionEvidence"] = evidence.actionSuccess
        diagnostics["executor"] = "window-agent-xpc"
        return WindowManagementEntryPointSmokeReport(
            entryPoint: "residentGlobalHotKey",
            action: action.rawValue,
            succeeded: result.succeeded,
            userMessage: result.userMessage,
            diagnostics: diagnostics
        )
    }

    private static func waitForRemoteAction(
        _ action: WindowLayoutAction,
        processID: Int32,
        client: WindowAgentXPCClient,
        timeout: TimeInterval
    ) throws -> WindowManagementResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reply = try sendRemote(
                WindowAgentRequest(operation: .fetchState, timeout: 1),
                using: client
            )
            if let state = reply.state,
               state.processID == processID,
               let result = state.lastResult,
               result.diagnosticFields["action"] == action.rawValue {
                guard result.succeeded else {
                    throw WindowManagementSmokeFailure(
                        result.userMessage ?? L10n.string(.WindowSettings.smokeTestHostShortcutActionFailed(String(describing: action.rawValue)))
                    )
                }
                return result
            }
            pumpApplicationEvents(for: 0.05)
        }
        throw WindowManagementSmokeFailure(
            L10n.string(.WindowSettings.smokeTestShortcutDidNotConverge(String(describing: processID), String(describing: action.rawValue)))
        )
    }

    private static func writeRemoteFailureReport(
        state: WindowAgentRuntimeSnapshot,
        screenLocked: Bool,
        message: String,
        action: String
    ) {
        writeReport(WindowManagementSmokeReport(
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            accessibilityTrusted: state.accessibilityTrusted,
            accessibilityOperational: state.accessibilityOperational,
            screenLocked: screenLocked,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessIdentifier: nil,
            screenCount: NSScreen.screens.count,
            skippedActions: WindowLayoutAction.allCases.map(\.rawValue),
            actions: [WindowManagementSmokeActionReport(
                action: action,
                succeeded: false,
                userMessage: message,
                diagnostics: [
                    "executor": "window-agent-xpc",
                    "agentPID": String(state.processID),
                    "agentLaunchID": state.launchID.uuidString,
                ]
            )],
            entryPoints: []
        ))
    }

    public static func writeReport(_ report: WindowManagementSmokeReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL, options: .atomic)
        }
        let lines = [
            L10n.string(.WindowSettings.smokeTestArcKitWindowManagementSmokeTestReport),
            "",
            L10n.string(.WindowSettings.smokeTestTime(String(describing: report.checkedAt))),
            L10n.string(.WindowSettings.smokeTestAccessibility(String(describing: report.accessibilityTrusted ? L10n.string(.Runtime.permissionsGranted) : L10n.string(.Runtime.permissionsNotGranted)))),
            L10n.string(.WindowSettings.smokeTestAccessibilityInterface(String(describing: report.accessibilityOperational ? L10n.string(.WindowSettings.smokeTestAvailable) : L10n.string(.WindowSettings.smokeTestUnavailable)))),
            L10n.string(.WindowSettings.smokeTestDesktopState(String(describing: report.screenLocked ? L10n.string(.WindowSettings.smokeTestLocked) : L10n.string(.WindowSettings.smokeTestUnlocked)))),
            L10n.string(.WindowSettings.smokeTestTargetApp(String(describing: report.targetBundleIdentifier))),
            L10n.string(.WindowSettings.smokeTestTargetPid(String(describing: report.targetProcessIdentifier.map(String.init) ?? "-"))),
            L10n.string(.WindowSettings.smokeTestDisplayCount(String(describing: report.screenCount))),
            L10n.string(.WindowSettings.smokeTestSkippedActions(String(describing: report.skippedActions.isEmpty ? L10n.string(.Common.none) : report.skippedActions.joined(separator: ", ")))),
            "",
            L10n.string(.WindowSettings.smokeTestActions),
            report.actions.isEmpty ? L10n.string(.WindowSettings.smokeTestSkippedMissingAccessibilityPrerequisites) : report.actions.map { action in
                "- \(action.action)：\(action.succeeded ? L10n.string(.Common.succeeded) : L10n.string(.Common.failed))\(action.userMessage.map { "（\($0)）" } ?? "")"
            }.joined(separator: "\n"),
            "",
            L10n.string(.WindowSettings.smokeTestLiveEntryPoints),
            report.entryPoints.isEmpty ? L10n.string(.WindowSettings.smokeTestNotRun) : report.entryPoints.map { entry in
                "- \(entry.entryPoint) / \(entry.action)：\(entry.succeeded ? L10n.string(.Common.succeeded) : L10n.string(.Common.failed))\(entry.userMessage.map { "（\($0)）" } ?? "")"
            }.joined(separator: "\n"),
            "",
        ]
        try? lines.joined(separator: "\n").write(to: markdownReportURL, atomically: true, encoding: .utf8)
    }

    private static func launchIsolatedHost() throws -> (application: NSRunningApplication, cleanupURL: URL) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: targetBundleIdentifier
        ) else {
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestTextEditMissing))
        }
        let taskDirectory = try ArcKitStoragePaths.current.makeTemporaryDirectory()
        let documentURL = taskDirectory.appendingPathComponent("WindowSmoke.txt")
        try L10n.string(.WindowSettings.smokeTestArcKitWindowManagementLiveSmokeTest).write(to: documentURL, atomically: true, encoding: .utf8)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false

        let launchResult = WorkspaceLaunchResultBox()
        // 只打开本次创建的临时文档，并绑定 NSWorkspace 返回的精确进程；绝不按 PID 差集猜实例。
        NSWorkspace.shared.open(
            [documentURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { application, error in
            launchResult.complete(application: application, error: error)
        }
        try waitUntil(timeout: 8, message: L10n.string(.WindowSettings.smokeTestTimeoutLaunchingIsolatedTexteditWindow)) { launchResult.isCompleted }
        let result = launchResult.result
        if let launchError = result.error {
            try? FileManager.default.removeItem(at: taskDirectory)
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestTextEditLaunchFailed(String(describing: launchError.localizedDescription))))
        }
        guard let application = result.application else {
            try? FileManager.default.removeItem(at: taskDirectory)
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestProcessMissing))
        }
        return (application, taskDirectory)
    }

    private static func waitUntil(timeout: TimeInterval, message: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        throw WindowManagementSmokeFailure(message)
    }

    private static func postHotKey(_ binding: WindowHotKeyBinding) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestShortcutEventFailed))
        }
        let modifierKeys: [(modifier: WindowHotKeyModifier, keyCode: CGKeyCode, flag: CGEventFlags)] = [
            (.control, 59, .maskControl),
            (.option, 58, .maskAlternate),
            (.shift, 56, .maskShift),
            (.command, 55, .maskCommand),
        ].filter { binding.modifiers.contains($0.modifier) }

        // RegisterEventHotKey 只认真实修饰键状态，不能只在主键事件上伪造 flags。
        var activeFlags: CGEventFlags = []
        for modifier in modifierKeys {
            activeFlags.insert(modifier.flag)
            try postKeyboardEvent(
                source: source,
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: activeFlags
            )
        }
        try postKeyboardEvent(
            source: source,
            keyCode: CGKeyCode(binding.keyCode),
            keyDown: true,
            flags: activeFlags
        )
        try postKeyboardEvent(
            source: source,
            keyCode: CGKeyCode(binding.keyCode),
            keyDown: false,
            flags: activeFlags
        )
        for modifier in modifierKeys.reversed() {
            activeFlags.remove(modifier.flag)
            try postKeyboardEvent(
                source: source,
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: activeFlags
            )
        }
    }

    /// 重复激活并要求前台状态稳定，避免真实入口烟测把其他用户窗口当成 TextEdit 目标。
    private static func activateAndWaitForFrontmost(
        _ application: NSRunningApplication,
        timeout: TimeInterval = 3,
        stableInterval: TimeInterval = 0.25
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        while Date() < deadline {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID == application.processIdentifier {
                if stableSince == nil { stableSince = Date() }
                if let stableSince,
                   Date().timeIntervalSince(stableSince) >= stableInterval {
                    // 稳定窗口覆盖了 Workspace 通知的真实分发时间，常驻进程此时应已记住目标。
                    return
                }
            } else {
                stableSince = nil
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            pumpApplicationEvents(for: 0.05)
        }
        let actual = NSWorkspace.shared.frontmostApplication
        throw WindowManagementSmokeFailure(
            L10n.string(.WindowSettings.smokeTestActivationFailed(String(describing: application.processIdentifier))) +
            "actualPID=\(actual?.processIdentifier.description ?? "-") actualBundle=\(actual?.bundleIdentifier ?? "-")"
        )
    }

    private static func postKeyboardEvent(
        source: CGEventSource,
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags
    ) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestKeyEventFailed(String(describing: keyCode))))
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        pumpApplicationEvents(for: 0.015)
    }

    private static func pumpApplicationEvents(for duration: TimeInterval) {
        let application = NSApplication.shared
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            let sliceDeadline = min(deadline, Date().addingTimeInterval(0.005))
            if let event = application.nextEvent(
                matching: .any,
                until: sliceDeadline,
                inMode: .default,
                dequeue: true
            ) {
                // Carbon 热键会以 systemDefined 事件进入 AppKit 队列，Foundation RunLoop 不会替 NSApplication 分发它。
                application.sendEvent(event)
            }
            RunLoop.current.run(mode: .default, before: sliceDeadline)
        } while Date() < deadline
    }

    private static func diagnosticLogSize() -> UInt64 {
        let url = ArcKitStoragePaths.current.logs.appendingPathComponent("host.jsonl")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return UInt64(max(0, size))
    }

    private static func waitForResidentHotKeyDiagnostics(
        processID: Int32,
        action: WindowLayoutAction,
        startingAt offset: UInt64,
        timeout: TimeInterval
    ) throws -> (callback: String, actionSuccess: String) {
        let deadline = Date().addingTimeInterval(timeout)
        let processMarker = "pid=\(processID) "
        let callbackMarker = "window hotkey pressed"
        let actionValueMarker = "action=\(action.rawValue)"
        let successMarker = "window action success action=\(action.rawValue)"
        let failureMarker = "window action failed"
        while Date() < deadline {
            let lines = diagnosticLogText(startingAt: offset).split(separator: "\n")
            if let callbackIndex = lines.firstIndex(where: {
                $0.contains(processMarker) && $0.contains(callbackMarker) && $0.contains(actionValueMarker)
            }) {
                let actionLines = lines[lines.index(after: callbackIndex)...]
                let successIndex = actionLines.firstIndex(where: {
                    $0.contains(processMarker) && $0.contains(successMarker)
                })
                let failureIndex = actionLines.firstIndex(where: {
                    $0.contains(processMarker) && $0.contains(failureMarker)
                })
                if let failureIndex, successIndex.map({ failureIndex < $0 }) ?? true {
                    throw WindowManagementSmokeFailure(L10n.string(.WindowSettings.smokeTestResidentHostShortcutFailed(String(describing: actionLines[failureIndex]))))
                }
                if let successIndex {
                    return (String(lines[callbackIndex]), String(actionLines[successIndex]))
                }
            }
            pumpApplicationEvents(for: 0.05)
        }
        throw WindowManagementSmokeFailure(
            L10n.string(.WindowSettings.smokeTestActionNotRecorded(String(describing: processID), String(describing: action.rawValue)))
        )
    }

    private static func diagnosticLogText(startingAt offset: UInt64) -> String {
        let maximumReadBytes: UInt64 = 1 * 1_024 * 1_024
        let url = ArcKitStoragePaths.current.logs.appendingPathComponent("host.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return "" }
        // 日志在 8 MiB 时会原地轮转；offset 超过新文件长度时必须从轮转后的文件重新读取。
        let requestedStart = offset <= fileSize ? offset : 0
        let start = max(requestedStart, fileSize > maximumReadBytes ? fileSize - maximumReadBytes : 0)
        let readCount = Int(min(maximumReadBytes, fileSize - start))
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: readCount) else { return "" }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func entryPointFailure(
        _ entryPoint: String,
        action: WindowLayoutAction,
        message: String
    ) -> WindowManagementEntryPointSmokeReport {
        WindowManagementEntryPointSmokeReport(
            entryPoint: entryPoint,
            action: action.rawValue,
            succeeded: false,
            userMessage: message,
            diagnostics: [:]
        )
    }
}

private struct WindowManagementSmokeFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
