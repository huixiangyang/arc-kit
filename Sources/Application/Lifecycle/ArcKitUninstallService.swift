import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import AppKit
import Foundation

public struct ArcKitUninstallPlan: Sendable {
    public let appBundleURL: URL
    public let requiredAppPath: String
    public let extensionURL: URL
    public let finderExtensionIdentifier: String
    public let plugInKitURL: URL
    public let launchServicesRegisterURL: URL
    public let killallURL: URL

    public init(
        appBundleURL: URL,
        requiredAppPath: String,
        extensionURL: URL,
        finderExtensionIdentifier: String = ArcKitConstants.finderExtensionBundleIdentifier,
        plugInKitURL: URL = URL(fileURLWithPath: "/usr/bin/pluginkit"),
        launchServicesRegisterURL: URL = URL(
            fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        ),
        killallURL: URL = URL(fileURLWithPath: "/usr/bin/killall")
    ) {
        self.appBundleURL = appBundleURL
        self.requiredAppPath = requiredAppPath
        self.extensionURL = extensionURL
        self.finderExtensionIdentifier = finderExtensionIdentifier
        self.plugInKitURL = plugInKitURL
        self.launchServicesRegisterURL = launchServicesRegisterURL
        self.killallURL = killallURL
    }

    @MainActor
    public static func installed() -> ArcKitUninstallPlan {
        let appURL = URL(fileURLWithPath: ArcKitConstants.installedAppPath, isDirectory: true)
        return ArcKitUninstallPlan(
            appBundleURL: appURL,
            requiredAppPath: ArcKitConstants.installedAppPath,
            extensionURL: appURL.appendingPathComponent(
                "Contents/PlugIns/ArcKitFinderExtension.appex",
                isDirectory: true
            )
        )
    }
}

public struct ArcKitUninstallCommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public struct ArcKitUninstallResult: Equatable, Sendable {
    public let trashedAppURL: URL

    public init(trashedAppURL: URL) {
        self.trashedAppURL = trashedAppURL
    }
}

public enum ArcKitUninstallError: LocalizedError, Equatable {
    case invalidInstallation(String)
    case commandFailed(String)
    case operationFailed(message: String, rollbackSucceeded: Bool)

    public var errorDescription: String? {
        switch self {
        case let .invalidInstallation(message), let .commandFailed(message):
            message
        case let .operationFailed(message, rollbackSucceeded):
            rollbackSucceeded
                ? L10n.string(.App.uninstallFinderExtensionStateRestoredRetry(String(describing: message)))
                : L10n.string(.App.uninstallExtensionRestoreIncomplete(String(describing: message)))
        }
    }
}

/// 卸载事务只管理 App 包、Finder 扩展和 LaunchServices。
/// 主 App 与Runtime Host 的生命周期必须由 SMAppService 在主线程独立处理。
public final class ArcKitUninstallCoordinator: @unchecked Sendable {
    public typealias CommandRunner = @Sendable (URL, [String]) -> ArcKitUninstallCommandResult
    public typealias TrashHandler = @Sendable (URL) throws -> URL

    private struct Snapshot {
        let extensionWasRegistered: Bool
        let extensionWasEnabled: Bool
    }

    private let plan: ArcKitUninstallPlan
    private let fileManager: FileManager
    private let commandRunner: CommandRunner
    private let trashHandler: TrashHandler

    public init(
        plan: ArcKitUninstallPlan,
        fileManager: FileManager = .default,
        commandRunner: @escaping CommandRunner = ArcKitUninstallCoordinator.runCommand,
        trashHandler: @escaping TrashHandler = ArcKitUninstallCoordinator.moveToTrash
    ) {
        self.plan = plan
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.trashHandler = trashHandler
    }

    @discardableResult
    public func execute(
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> ArcKitUninstallResult {
        progress(L10n.string(.App.uninstallCheckingArcKitInstallationLocation))
        try validateInstallation()
        let snapshot = try captureSnapshot()

        do {
            progress(L10n.string(.App.uninstallRemovingFinderExtensionRegistration))
            unregisterFinderExtension(snapshot: snapshot)
            try verifyExtensionCleanup()

            progress(L10n.string(.App.uninstallMovingArcKitTrash))
            let trashedURL = try trashHandler(plan.appBundleURL)
            guard !fileManager.fileExists(atPath: plan.appBundleURL.path),
                  fileManager.fileExists(atPath: trashedURL.path)
            else {
                throw ArcKitUninstallError.commandFailed(L10n.string(.App.uninstallTrashIncomplete))
            }

            progress(L10n.string(.App.uninstallUninstallPreparationCompleteQuittingArcKit))
            return ArcKitUninstallResult(trashedAppURL: trashedURL)
        } catch {
            let restored = restore(snapshot: snapshot)
            throw ArcKitUninstallError.operationFailed(
                message: error.localizedDescription,
                rollbackSucceeded: restored
            )
        }
    }

    private func validateInstallation() throws {
        let actualPath = plan.appBundleURL.standardizedFileURL.path
        let requiredPath = URL(fileURLWithPath: plan.requiredAppPath, isDirectory: true)
            .standardizedFileURL.path
        guard actualPath == requiredPath,
              plan.appBundleURL.lastPathComponent == "Arc Kit.app",
              plan.appBundleURL.pathExtension == "app",
              fileManager.fileExists(atPath: plan.appBundleURL.path)
        else {
            throw ArcKitUninstallError.invalidInstallation(L10n.string(.App.uninstallCurrentInstallationUninstalled(String(describing: plan.requiredAppPath))))
        }

        let infoURL = plan.appBundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? ArcKitBoundedFileReader.read(
            from: infoURL,
            maximumBytes: 1 * 1_024 * 1_024
        ),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == ArcKitConstants.appBundleIdentifier
        else {
            throw ArcKitUninstallError.invalidInstallation(L10n.string(.App.uninstallIdentityVerificationFailed))
        }

        let expectedExtension = plan.appBundleURL
            .appendingPathComponent(
                "Contents/PlugIns/ArcKitFinderExtension.appex",
                isDirectory: true
            )
            .standardizedFileURL.path
        guard plan.extensionURL.standardizedFileURL.path == expectedExtension else {
            throw ArcKitUninstallError.invalidInstallation(L10n.string(.App.uninstallFinderExtensionPathOutside))
        }
    }

    private func captureSnapshot() throws -> Snapshot {
        let status = queryExtensionStatus()
        guard status.commandSucceeded else {
            throw ArcKitUninstallError.commandFailed(L10n.string(.App.uninstallRegistrationUnreadable))
        }
        return Snapshot(
            extensionWasRegistered: status.matchingLine != nil,
            extensionWasEnabled: status.matchingLine?
                .trimmingCharacters(in: .whitespaces)
                .hasPrefix("+") == true
        )
    }

    private func unregisterFinderExtension(snapshot: Snapshot) {
        if snapshot.extensionWasRegistered {
            _ = commandRunner(plan.plugInKitURL, [
                "-e", "ignore", "-i", plan.finderExtensionIdentifier,
            ])
            _ = commandRunner(plan.plugInKitURL, ["-r", plan.extensionURL.path])
        }
        _ = commandRunner(plan.launchServicesRegisterURL, ["-u", plan.appBundleURL.path])
        _ = commandRunner(plan.killallURL, ["Finder"])
    }

    private func verifyExtensionCleanup() throws {
        let status = queryExtensionStatus()
        guard status.commandSucceeded, status.matchingLine == nil else {
            throw ArcKitUninstallError.commandFailed(L10n.string(.App.uninstallFinderExtensionStillRegistered))
        }
    }

    private func restore(snapshot: Snapshot) -> Bool {
        var succeeded = true
        if snapshot.extensionWasRegistered {
            succeeded = commandRunner(plan.plugInKitURL, ["-a", plan.extensionURL.path]).status == 0
                && succeeded
            let mode = snapshot.extensionWasEnabled ? "use" : "ignore"
            succeeded = commandRunner(plan.plugInKitURL, [
                "-e", mode, "-i", plan.finderExtensionIdentifier,
            ]).status == 0 && succeeded
        }
        _ = commandRunner(plan.launchServicesRegisterURL, ["-f", plan.appBundleURL.path])
        _ = commandRunner(plan.killallURL, ["Finder"])

        let status = queryExtensionStatus()
        let restored = snapshot.extensionWasRegistered
            ? status.commandSucceeded && status.matchingLine != nil
            : status.commandSucceeded && status.matchingLine == nil
        return succeeded && restored
    }

    private func queryExtensionStatus() -> (commandSucceeded: Bool, matchingLine: String?) {
        let result = commandRunner(plan.plugInKitURL, [
            "-m", "-A", "-D", "-v", "-i", plan.finderExtensionIdentifier,
        ])
        let matchingLine = result.output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains(plan.extensionURL.path) })
        return (result.status == 0, matchingLine)
    }

    public static func runCommand(
        executable: URL,
        arguments: [String]
    ) -> ArcKitUninstallCommandResult {
        switch ShellExecutor.runCapturingMergedOutput(
            executableURL: executable,
            arguments: arguments,
            timeout: 10
        ) {
        case let .completed(status, output):
            return ArcKitUninstallCommandResult(
                status: status,
                output: output
            )
        case .timedOut:
            return ArcKitUninstallCommandResult(status: -1, output: L10n.string(.App.uninstallCommandTimeout))
        case .outputLimitExceeded:
            return ArcKitUninstallCommandResult(status: -1, output: L10n.string(.App.uninstallOutputLimit))
        case let .launchFailed(message):
            return ArcKitUninstallCommandResult(status: -1, output: message)
        }
    }

    public static func moveToTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw ArcKitUninstallError.commandFailed(L10n.string(.App.uninstallSystemReturnedArcKitPathMissing))
        }
        return resultingURL as URL
    }
}

@MainActor
public final class ArcKitUninstallService: ObservableObject {
    public enum State: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    private let coordinator: ArcKitUninstallCoordinator
    private var task: Task<Void, Never>?

    public convenience init() {
        self.init(coordinator: ArcKitUninstallCoordinator(plan: .installed()))
    }

    public init(coordinator: ArcKitUninstallCoordinator) {
        self.coordinator = coordinator
    }

    public var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    public func uninstall(
        onFailure: @escaping @MainActor () -> Void = {},
        onSuccess: @escaping @MainActor (ArcKitUninstallResult) -> Void
    ) {
        guard !isWorking else { return }
        state = .working(L10n.string(.App.uninstallCheckingArcKitInstallationLocation))
        let coordinator = coordinator
        task = Task { [weak self] in
            let (progressStream, progressContinuation) = AsyncStream<String>.makeStream()
            let progressTask = Task { @MainActor [weak self] in
                for await message in progressStream {
                    guard let self, self.isWorking else { return }
                    self.state = .working(message)
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try coordinator.execute { message in
                        progressContinuation.yield(message)
                    }
                }.value
                progressContinuation.finish()
                await progressTask.value
                guard let self else { return }
                self.task = nil
                onSuccess(result)
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                guard let self else { return }
                self.task = nil
                onFailure()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func clearFailure() {
        guard case .failed = state else { return }
        state = .idle
    }
}
