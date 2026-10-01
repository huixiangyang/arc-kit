import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import Darwin
import FinderSync
import Foundation
import ServiceManagement

/// Finder 扩展状态检测服务。
enum FinderExtensionStatusService {
    struct HealthStatus: Equatable, Sendable {
        var checkedAt: Date
        var snapshotExists: Bool
        var snapshotAgeDescription: String
        var extensionFileExists: Bool
        var expectedExtensionPath: String
        var extensionEnabledByUser: Bool
        var extensionRuntimeResponded: Bool
        var extensionRuntimeAgeDescription: String
        var plugInKitRegistered: Bool
        var plugInKitPathVerified: Bool
        var plugInKitOnlyCurrentPath: Bool
        var plugInKitSummary: String
        var agentFileExists: Bool
        var agentRunning: Bool
        var agentProcessPathVerified: Bool
        var agentOnlyCurrentProcess: Bool
        var agentProcessSummary: String
        var launchAgentPlistExists: Bool
        var launchAgentSecureServiceConfigured: Bool
        var launchAgentLoaded: Bool
        var launchAgentDescription: String
        var commandChannelDescription: String

        var finderEnabled: Bool = true
        var launchAgentRequiresApproval: Bool = false

        var criticalChecksPassed: Bool {
            if !finderEnabled { return true }
            return snapshotExists
                && extensionFileExists
                && extensionEnabledByUser
                && extensionRuntimeResponded
                && plugInKitRegistered
                && plugInKitPathVerified
                && plugInKitOnlyCurrentPath
                && agentFileExists
                && (!agentRunning || (agentProcessPathVerified && agentOnlyCurrentProcess))
                && launchAgentPlistExists
                && launchAgentSecureServiceConfigured
                && launchAgentLoaded
        }

        var checkedAtDescription: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return formatter.string(from: checkedAt)
        }
    }

    struct RepairStep: Equatable, Sendable {
        var title: String
        var succeeded: Bool
        var detail: String
    }

    struct RepairReport: Equatable, Sendable {
        var steps: [RepairStep]

        var succeeded: Bool {
            steps.allSatisfy(\.succeeded)
        }

        var title: String {
            succeeded ? L10n.string(.FinderSettings.extensionFinderRepairStepsCompleted) : L10n.string(.FinderSettings.extensionFinderRepairStepsIncomplete)
        }

        var message: String {
            steps.map { step in
                "[\(step.succeeded ? L10n.string(.FinderSettings.extensionPassed) : L10n.string(.Common.failed))] \(step.title)：\(step.detail)"
            }.joined(separator: "\n")
        }
    }

    /// 通过 pluginkit 查询系统是否已识别 Arc Kit Finder 扩展。
    /// 主 App 进程内读取 FIFinderSyncController.directoryURLs 不可靠，未运行扩展时也可能为空。
    static func isExtensionRegistered() -> Bool {
        healthStatus().plugInKitPathVerified
    }

    static func installedExtensionFileExists() -> Bool {
        FileManager.default.fileExists(atPath: "\(ArcKitConstants.installedAppPath)/Contents/PlugIns/ArcKitFinderExtension.appex")
    }

    /// PlugInKit 注册只代表系统识别了扩展；是否允许 Finder 调用必须使用官方宿主 API 判断。
    static func isExtensionEnabledByUser() -> Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    static func showExtensionManagementInterface() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    static func registrationSummary() -> String {
        ShellExecutor.runWithOutput(
            "pluginkit -m -A -D -v -i \(ShellQuoting.shellQuoted(ArcKitConstants.finderExtensionBundleIdentifier))",
            timeout: 10
        )
            ?? L10n.string(.FinderSettings.extensionRegistrationMissing)
    }

    static func isFinderAgentRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier).isEmpty
    }

    static func finderAgentLoginItemStatusDescription() -> String {
        L10n.string(.FinderSettings.extensionManagedSmappservice)
    }

    static func finderAgentLaunchAgentStatusDescription() -> String {
        managedFinderAgentStatusDescription()
    }

    static func finderSharedStorageDescription() -> String {
        L10n.string(.FinderSettings.extensionSnapshotTransport)
    }

    static func diagnosticIsFinderAgentRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ArcKitConstants.runtimeHostBundleIdentifier).isEmpty
    }

    static func diagnosticLaunchAgentStatusDescription() -> String {
        managedFinderAgentStatusDescription()
    }

    /// 回执最多等两秒，只轮询小型状态文件；昂贵的系统注册检查每轮执行一次。
    static func refreshHealth(
        snapshotStore: FinderExtensionSnapshotStore = FinderExtensionSnapshotStore(),
        runtimeStateStore: FinderExtensionRuntimeStateStore = FinderExtensionRuntimeStateStore(),
        reason: String = "health-check"
    ) async -> HealthStatus {
        await Task.detached(priority: .utility) {
            let requestID = UUID()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            FinderCommandIPC.postFinderExtensionRuntimeStateRequest(requestID: requestID, reason: reason)
            repeat {
                let states = (try? runtimeStateStore.loadAll()) ?? []
                if extensionHasResponse(states, requestID: requestID, now: Date()) { break }
                try? await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            return healthStatus(snapshotStore: snapshotStore, runtimeStateStore: runtimeStateStore,
                                now: Date(), responseRequestID: requestID)
        }.value
    }

    static func extensionHasResponse(
        _ states: [FinderExtensionRuntimeState], requestID: UUID?, now: Date,
        isRunning: (Int32) -> Bool = { processIsRunning(pid: $0) }
    ) -> Bool {
        let extensionPath = ArcKitConstants.installedAppPath + "/Contents/PlugIns/ArcKitFinderExtension.appex"
        return states.contains { state in
            state.hasRecentResponse(to: requestID, now: now)
                && state.bundleIdentifier == ArcKitConstants.finderExtensionBundleIdentifier
                && state.bundlePath == extensionPath
                && state.executablePath == extensionPath + "/Contents/MacOS/ArcKitFinderExtension"
                && isRunning(state.processID)
        }
    }

    static func healthStatus(
        snapshotStore: FinderExtensionSnapshotStore = FinderExtensionSnapshotStore(),
        runtimeStateStore: FinderExtensionRuntimeStateStore = FinderExtensionRuntimeStateStore(),
        now: Date = Date(),
        responseRequestID: UUID? = nil
    ) -> HealthStatus {
        let expectedExtensionPath = "\(ArcKitConstants.installedAppPath)/Contents/PlugIns/ArcKitFinderExtension.appex"
        let agentPath = ArcKitConstants.installedRuntimeHostPath
        let launchAgentPath = ArcKitConstants.installedAppPath +
            "/Contents/Library/LaunchAgents/com.archalo.arckit.runtime-host.plist"
        let plugInKitSummary = registrationSummary()
        let plugInKitStatus = parsePlugInKitStatus(
            summary: plugInKitSummary,
            expectedExtensionPath: expectedExtensionPath
        )
        let launchAgentDescription = managedFinderAgentStatusDescription()
        let launchAgentStatus = SMAppService.agent(plistName: "com.archalo.arckit.runtime-host.plist").status
        let launchAgentSecureServiceConfigured = launchAgentPlistConfiguresSecureService(
            path: launchAgentPath,
            expectedExecutablePath: ArcKitConstants.installedRuntimeHostExecutablePath
        )
        let agentProcessSummary = finderAgentProcessSummary()
        let agentProcessStatus = parseFinderAgentProcessStatus(
            summary: agentProcessSummary,
            expectedExecutablePath: ArcKitConstants.installedRuntimeHostExecutablePath
        )
        let checkedAt = now
        let extensionRuntimeStates = (try? runtimeStateStore.loadAll()) ?? []
        let extensionRuntimeResponded = extensionHasResponse(
            extensionRuntimeStates, requestID: responseRequestID, now: checkedAt
        )
        let responseAge = extensionRuntimeStates.flatMap(\.recentStateResponses)
            .filter { responseRequestID == nil || $0.requestID == responseRequestID }
            .map { checkedAt.timeIntervalSince($0.respondedAt) }
            .filter { $0 >= 0 }.min()


        return HealthStatus(
            checkedAt: checkedAt,
            snapshotExists: snapshotStore.load() != nil,
            snapshotAgeDescription: snapshotStore.latestSnapshotAgeDescription(now: now),
            extensionFileExists: FileManager.default.fileExists(atPath: expectedExtensionPath),
            expectedExtensionPath: expectedExtensionPath,
            extensionEnabledByUser: isExtensionEnabledByUser(),
            extensionRuntimeResponded: extensionRuntimeResponded,
            extensionRuntimeAgeDescription: responseAge.map(ageDescription) ?? L10n.string(.FinderSettings.extensionNotReceived),
            plugInKitRegistered: plugInKitStatus.registered,
            plugInKitPathVerified: plugInKitStatus.pathVerified,
            plugInKitOnlyCurrentPath: plugInKitStatus.onlyCurrentPath,
            plugInKitSummary: plugInKitSummary,
            agentFileExists: FileManager.default.fileExists(atPath: agentPath),
            agentRunning: agentProcessStatus.running,
            agentProcessPathVerified: agentProcessStatus.pathVerified,
            agentOnlyCurrentProcess: agentProcessStatus.onlyCurrentProcess,
            agentProcessSummary: agentProcessSummary,
            launchAgentPlistExists: FileManager.default.fileExists(atPath: launchAgentPath),
            launchAgentSecureServiceConfigured: launchAgentSecureServiceConfigured,
            launchAgentLoaded: launchAgentStatus == .enabled,
            launchAgentDescription: launchAgentDescription,
            commandChannelDescription: finderSharedStorageDescription(),
            finderEnabled: snapshotStore.load()?.menuProfile.isEnabled ?? true,
            launchAgentRequiresApproval: launchAgentStatus == .requiresApproval
        )
    }

    private static func processIsRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    private static func ageDescription(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds))
        if wholeSeconds < 60 { return L10n.string(.FinderSettings.extensionSAgo(String(describing: wholeSeconds))) }
        let minutes = wholeSeconds / 60
        if minutes < 60 { return L10n.string(.FinderSettings.extensionMAgo(String(describing: minutes))) }
        return L10n.string(.FinderSettings.extensionHAgo(String(describing: minutes / 60)))
    }

    static func repairFinderExtension(
        settings: FinderRuntimeSettings,
        snapshotStore: FinderExtensionSnapshotStore
    ) -> RepairReport {
        var steps: [RepairStep] = []
        let extensionPath = "\(ArcKitConstants.installedAppPath)/Contents/PlugIns/ArcKitFinderExtension.appex"
        let agentPath = ArcKitConstants.installedRuntimeHostPath

        let snapshot = FinderExtensionSnapshot.make(
            settings: settings,
            applicationAvailability: { FavoriteApplicationAvailabilityResolver.isAvailable($0) }
        )
        snapshotStore.publish(snapshot, reason: "manual-repair")
        steps.append(.init(title: L10n.string(.FinderSettings.extensionNotifyMenuConfigurationRefresh), succeeded: true, detail: L10n.string(.FinderSettings.extensionVersionFinderExtensionFetch(String(describing: snapshot.schemaVersion)))))

        if FileManager.default.fileExists(atPath: extensionPath) {
            steps.append(.init(title: L10n.string(.FinderSettings.extensionCheckFinderExtensionFiles), succeeded: true, detail: extensionPath))
        } else {
            steps.append(.init(title: L10n.string(.FinderSettings.extensionCheckFinderExtensionFiles), succeeded: false, detail: L10n.string(.FinderSettings.extensionMissing(String(describing: extensionPath)))))
        }

        if FileManager.default.fileExists(atPath: agentPath) {
            steps.append(.init(title: L10n.string(.FinderSettings.extensionCheckHost), succeeded: true, detail: agentPath))
        } else {
            steps.append(.init(title: L10n.string(.FinderSettings.extensionCheckHost), succeeded: false, detail: L10n.string(.FinderSettings.extensionMissing(String(describing: agentPath)))))
        }

        let cleanupPlugInKit = unregisterExistingPlugInKitRegistrations(
            summary: registrationSummary(),
            expectedExtensionPath: extensionPath
        )
        steps.append(.init(
            title: L10n.string(.FinderSettings.extensionRemoveOldFinderExtensionRegistrations),
            succeeded: cleanupPlugInKit.succeeded,
            detail: cleanupPlugInKit.detail
        ))

        let registerCommand = "pluginkit -a \(ShellQuoting.shellQuoted(extensionPath))"
        let registered = ShellExecutor.run(registerCommand, timeout: 10)
        steps.append(.init(title: L10n.string(.FinderSettings.extensionRegisterFinderExtension), succeeded: registered, detail: registered ? L10n.string(.FinderSettings.extensionPluginkitAcceptedCurrentExtensionPath) : L10n.string(.FinderSettings.extensionPluginkitRegistrationFailed)))

        // 修复注册不代替用户开启扩展；尊重系统设置中的禁用选择。
        let enabledByUser = isExtensionEnabledByUser()
        steps.append(.init(
            title: L10n.string(.FinderSettings.extensionCheckUserEnablement),
            succeeded: enabledByUser,
            detail: enabledByUser ? L10n.string(.FinderSettings.extensionFinderAllowsArcKitExtension) : L10n.string(.FinderSettings.extensionEnableArcKitManuallySystemExtension)
        ))

        let pathVerified = verifyPlugInKitPath(extensionPath)
        steps.append(.init(title: L10n.string(.FinderSettings.extensionVerifyUniquePluginkitPath), succeeded: pathVerified, detail: pathVerified ? extensionPath : L10n.string(.FinderSettings.extensionRegistrationAmbiguous)))

        let hostEnabled = SMAppService.agent(plistName: "com.archalo.arckit.runtime-host.plist").status == .enabled
        steps.append(.init(title: L10n.string(.FinderSettings.extensionCheckBackgroundRegistration), succeeded: hostEnabled,
            detail: hostEnabled ? L10n.string(.FinderSettings.extensionRegisteredProcessWhileIdleNormalMissing) : L10n.string(.FinderSettings.extensionEnableFeatureArcKit)))

        let finderRestarted = ShellExecutor.run("killall Finder", timeout: 10)
        steps.append(.init(title: L10n.string(.FinderSettings.extensionRestartFinder), succeeded: finderRestarted, detail: finderRestarted ? L10n.string(.FinderSettings.extensionFinderRestartedExtensionReload) : L10n.string(.FinderSettings.extensionKillallFinderFailed)))

        let report = RepairReport(steps: steps)
        ArcKitLog.append(
            "repair finder extension finished succeeded=\(report.succeeded) steps=" +
            steps.map { "\($0.title)=\($0.succeeded ? "ok" : "failed")" }.joined(separator: ",")
        )
        return report
    }

    private static func verifyPlugInKitPath(_ extensionPath: String) -> Bool {
        parsePlugInKitStatus(
            summary: registrationSummary(),
            expectedExtensionPath: extensionPath
        ).onlyCurrentPath
    }

    private static func unregisterExistingPlugInKitRegistrations(
        summary: String,
        expectedExtensionPath: String
    ) -> (succeeded: Bool, detail: String) {
        var paths = Array(Set(parsePlugInKitRegisteredPaths(summary: summary))).sorted()
        guard !paths.isEmpty else {
            return (true, L10n.string(.FinderSettings.extensionOldPluginkitRegistrationsFoundMissing))
        }
        let initialPaths = paths
        for _ in 1...3 {
            let failed = paths.filter { path in
                !ShellExecutor.run(
                    "pluginkit -r \(ShellQuoting.shellQuoted(path))",
                    timeout: 10
                )
            }
            if !failed.isEmpty {
                return (false, L10n.string(.FinderSettings.extensionRegistrationRemovalFailed(String(describing: failed.joined(separator: "，")))))
            }
            Thread.sleep(forTimeInterval: 0.2)
            paths = Array(Set(parsePlugInKitRegisteredPaths(summary: registrationSummary()))).sorted()
            if paths.isEmpty {
                let currentMarker = initialPaths.contains(expectedExtensionPath) ? L10n.string(.FinderSettings.extensionIncludingCurrentPathCleanedRe) : ""
                return (true, L10n.string(.FinderSettings.extensionRemovedInstallationPaths(String(describing: initialPaths.count), String(describing: currentMarker))))
            }
        }
        return (false, L10n.string(.FinderSettings.extensionPathsRemainPluginkitCleanup(String(describing: paths.joined(separator: "，")))))
    }

    static func launchAgentPlistConfiguresSecureService(
        path: String,
        expectedExecutablePath: String
    ) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              dictionary["Label"] as? String == ArcKitConstants.runtimeHostLaunchAgentIdentifier,
              let machServices = dictionary["MachServices"] as? [String: Any],
              machServices[ArcKitConstants.finderRuntimeMachServiceName] as? Bool == true
        else { return false }
        let managedBundleProgram = dictionary["BundleProgram"] as? String
        let expectedBundleProgram = ArcKitConstants.runtimeHostRelativePath +
            "/Contents/MacOS/ArcKitRuntimeHost"
        return managedBundleProgram == expectedBundleProgram
    }

    private static func managedFinderAgentStatusDescription() -> String {
        switch SMAppService.agent(plistName: "com.archalo.arckit.runtime-host.plist").status {
        case .enabled: "enabled"
        case .notRegistered: "not-registered"
        case .requiresApproval: "requires-approval"
        case .notFound: "not-found"
        @unknown default: "unknown"
        }
    }

    private static func finderAgentProcessSummary() -> String {
        ShellExecutor.runWithOutput(finderAgentProcessQueryCommand, timeout: 10)
            ?? L10n.string(.FinderSettings.extensionArckitruntimehostProcessMissing)
    }

    /// 先按内核进程名精确筛选 PID，再读取完整 argv；禁止用 `pgrep -f` 把测试
    /// Runner、诊断命令或仅在参数里出现 Agent 名称的无关进程误杀。
    static let finderAgentProcessQueryCommand =
        "for pid in $(/usr/bin/pgrep -x ArcKitRuntimeHost 2>/dev/null); " +
        "do /bin/ps -p \"$pid\" -o pid=,args=; done"

    private static func isCurrentFinderAgentRunning() -> Bool {
        parseFinderAgentProcessStatus(
            summary: finderAgentProcessSummary(),
            expectedExecutablePath: ArcKitConstants.installedRuntimeHostExecutablePath
        ).onlyCurrentProcess
    }

    static func parsePlugInKitStatus(summary: String, expectedExtensionPath: String) -> (registered: Bool, pathVerified: Bool, onlyCurrentPath: Bool) {
        let paths = Array(Set(parsePlugInKitRegisteredPaths(summary: summary))).sorted()
        let currentLines = paths.filter { $0 == expectedExtensionPath }
        let registered = !paths.isEmpty
        let pathVerified = !currentLines.isEmpty
        let onlyCurrentPath = registered && paths == [expectedExtensionPath]
        return (registered, pathVerified, onlyCurrentPath)
    }

    static func parsePlugInKitRegisteredPaths(summary: String) -> [String] {
        summary
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.contains(ArcKitConstants.finderExtensionBundleIdentifier),
                      let pathStart = line.firstIndex(of: "/")
                else { return nil }
                return String(line[pathStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    static func parseFinderAgentProcesses(
        summary: String,
        executablePath: (Int32) -> String? = ProcessExecutablePath.read
    ) -> [(pid: Int32, path: String?)] {
        summary
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> (pid: Int32, path: String?)? in
                let line = String(rawLine)
                guard line.contains("ArcKitRuntimeHost"), !line.contains("--operation-worker") else { return nil }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let firstPart = trimmed.split(separator: " ").first,
                      let pid = Int32(firstPart)
                else { return nil }
                // argv 只用于区分短命 Worker；安装路径必须来自内核，读取失败不冒充健康。
                return (pid, executablePath(pid))
            }
    }

    static func parseFinderAgentProcessStatus(
        summary: String,
        expectedExecutablePath: String,
        executablePath: (Int32) -> String? = ProcessExecutablePath.read
    ) -> (running: Bool, pathVerified: Bool, onlyCurrentProcess: Bool) {
        let lines = parseFinderAgentProcesses(summary: summary, executablePath: executablePath)
        let currentLines = lines.filter { $0.path == expectedExecutablePath }
        return (
            running: !lines.isEmpty,
            pathVerified: !currentLines.isEmpty,
            onlyCurrentProcess: currentLines.count == 1 && lines.count == currentLines.count
        )
    }

    static func isLaunchAgentLoaded(description: String) -> Bool {
        description.contains("state = running") || description.contains("state = waiting")
    }
}
