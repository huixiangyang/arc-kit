import ArcKitPlatform
import AppKit
import Foundation

/// 系统增强执行层：隐藏文件、截图位置等，统一使用 ShellExecutor。
@MainActor
public final class SystemEnhancementService: ObservableObject {
    public enum HiddenFilesState: Equatable {
        case unknown
        case enabled
        case disabled
    }

    @Published public private(set) var hiddenFilesState: HiddenFilesState = .unknown
    @Published public private(set) var screenshotLocationPath: String?
    @Published public private(set) var hiddenFilesError: String?
    @Published public private(set) var screenshotLocationError: String?
    @Published public private(set) var isTogglingHiddenFiles = false

    private let commandBuilder = SystemEnhancementCommandBuilder()
    private let runCommand: (String) -> Bool
    private let runWithOutput: (String, Bool) -> String?
    private let writableDirectoryChecker: (String) -> Bool
    /// 串行化 toggle 操作，防止连续点击导致并行 killall Finder 竞态
    private var isToggling = false

    public convenience init() {
        self.init(autoRefresh: true)
    }

    init(
        commandRunner: @escaping (String) -> Bool = {
            ShellExecutor.run($0, timeout: 10)
        },
        outputRunner: ((String) -> String?)? = nil,
        outputRunnerWithFailureLogging: ((String, Bool) -> String?)? = nil,
        writableDirectoryChecker: ((String) -> Bool)? = nil,
        autoRefresh: Bool
    ) {
        self.runCommand = commandRunner
        if let outputRunnerWithFailureLogging {
            self.runWithOutput = outputRunnerWithFailureLogging
        } else if let outputRunner {
            self.runWithOutput = { command, _ in outputRunner(command) }
        } else {
            self.runWithOutput = { command, logsFailure in
                ShellExecutor.runWithOutput(command, timeout: 10, logsFailure: logsFailure)
            }
        }
        self.writableDirectoryChecker = writableDirectoryChecker ?? { path in
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return false
            }
            return FileManager.default.isWritableFile(atPath: path)
        }
        if autoRefresh {
            refresh()
        }
    }

    public func refresh() {
        hiddenFilesState = readHiddenFilesState()
        screenshotLocationPath = readScreenshotLocation()
    }

    public var screenshotLocationDescription: String {
        guard let screenshotLocationPath else { return L10n.string(.Settings.systemDesktopSystemDefault) }
        return NSString(string: screenshotLocationPath).abbreviatingWithTildeInPath
    }

    public var isScreenshotLocationDefault: Bool {
        screenshotLocationPath == nil
    }

    public func refreshHiddenFilesState() {
        hiddenFilesState = readHiddenFilesState()
        hiddenFilesError = hiddenFilesState == .unknown
            ? L10n.string(.Settings.systemHiddenFilesReadFailed)
            : nil
    }

    public func clearHiddenFilesError() {
        hiddenFilesError = nil
    }

    public func clearScreenshotLocationError() {
        screenshotLocationError = nil
    }

    public func toggleHiddenFilesAndRestartFinder() {
        guard !isToggling else {
            hiddenFilesError = L10n.string(.Settings.systemApplyingHiddenFileSettingsPleaseWait)
            return
        }
        let nextEnabled: Bool
        switch hiddenFilesState {
        case .enabled:
            nextEnabled = false
        case .disabled:
            nextEnabled = true
        case .unknown:
            hiddenFilesError = L10n.string(.Settings.systemStateUnconfirmed)
            return
        }
        isToggling = true
        isTogglingHiddenFiles = true

        guard runCommand(commandBuilder.setHiddenFilesCommand(enabled: nextEnabled)) else {
            hiddenFilesError = nextEnabled ? L10n.string(.Settings.systemShowHiddenFilesFailed) : L10n.string(.Settings.systemHideHiddenFilesFailed)
            isToggling = false
            isTogglingHiddenFiles = false
            ArcKitLog.append("system hidden files set failed nextEnabled=\(nextEnabled)")
            return
        }
        guard runCommand(commandBuilder.restartFinderCommand()) else {
            refresh()
            hiddenFilesError = L10n.string(.Settings.systemFinderRestartFailed)
            isToggling = false
            isTogglingHiddenFiles = false
            ArcKitLog.append("system hidden files partial restartFinderFailed nextEnabled=\(nextEnabled)")
            return
        }
        // 等待 Finder 重启后读取真实状态，确保状态与系统一致
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
            if self?.hiddenFilesState == .unknown {
                self?.hiddenFilesError = L10n.string(.Settings.systemFinderRestartedHiddenFileState)
            }
            self?.isToggling = false
            self?.isTogglingHiddenFiles = false
        }
        hiddenFilesError = nil
        ArcKitLog.append("system hidden files toggled nextEnabled=\(nextEnabled)")
    }

    public func chooseScreenshotLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string(.Settings.systemUseFolder)
        panel.message = L10n.string(.Settings.systemChooseWhereSaveNewScreenshotsExisting)
        panel.directoryURL = screenshotLocationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setScreenshotLocation(url.path)
    }

    public func resetScreenshotLocation() {
        guard !isScreenshotLocationDefault else {
            screenshotLocationError = nil
            return
        }
        guard resetScreenshotLocationDefault() else {
            screenshotLocationError = L10n.string(.Settings.systemScreenshotResetFailed)
            ArcKitLog.append("system screenshot reset failed")
            return
        }
        guard restartSystemUIServerAfterScreenshotChange() else {
            screenshotLocationPath = nil
            screenshotLocationError = L10n.string(.Settings.systemScreenshotResetRestartFailed)
            ArcKitLog.append("system screenshot reset partial restartSystemUIServerFailed")
            return
        }
        screenshotLocationPath = nil
        screenshotLocationError = nil
        ArcKitLog.append("system screenshot reset success")
    }

    func setScreenshotLocation(_ path: String) {
        guard writableDirectoryChecker(path) else {
            screenshotLocationError = L10n.string(.Settings.systemScreenshotLocationInvalid(String(describing: path)))
            ArcKitLog.append("system screenshot set rejected path=\(path)")
            return
        }
        guard runCommand(commandBuilder.setScreenshotLocationCommand(path: path)) else {
            screenshotLocationError = L10n.string(.Settings.systemScreenshotLocationFailed(String(describing: path)))
            ArcKitLog.append("system screenshot set failed path=\(path)")
            return
        }
        guard restartSystemUIServerAfterScreenshotChange() else {
            screenshotLocationPath = path
            screenshotLocationError = L10n.string(.Settings.systemScreenshotRestartFailed)
            ArcKitLog.append("system screenshot set partial restartSystemUIServerFailed path=\(path)")
            return
        }
        screenshotLocationPath = path
        screenshotLocationError = nil
        ArcKitLog.append("system screenshot set success path=\(path)")
    }

    private func readHiddenFilesState() -> HiddenFilesState {
        guard let output = runWithOutput(commandBuilder.readHiddenFilesCommand(), true) else {
            return .unknown
        }
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes"].contains(normalized) { return .enabled }
        if ["0", "false", "no"].contains(normalized) { return .disabled }
        return .unknown
    }

    private func readScreenshotLocation() -> String? {
        // `defaults read ... location` 在用户未设置自定义截图目录时会返回非 0；
        // 这是“默认位置”的正常状态，不应污染诊断日志。
        guard let output = runWithOutput(commandBuilder.readScreenshotLocationCommand(), false) else {
            return nil
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func resetScreenshotLocationDefault() -> Bool {
        if runCommand(commandBuilder.resetScreenshotLocationCommand()) {
            return true
        }
        // `defaults delete` 在用户本来就是默认位置时会失败；只要读不到自定义位置，就视为已处于默认状态。
        return readScreenshotLocation() == nil
    }

    private func restartSystemUIServerAfterScreenshotChange() -> Bool {
        runCommand(commandBuilder.restartSystemUIServerCommand())
    }


}
