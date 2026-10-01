import ArcKitPlatform
import Combine
import Foundation
@preconcurrency import Sparkle

/// 更新检查、下载、EdDSA 校验与安装统一交给 Sparkle；预览和测试不会启动更新器。
@MainActor
public final class ArcKitUpdateService: ObservableObject {
    @Published public private(set) var isAvailable = false
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticChecksEnabled = false
    @Published public private(set) var automaticDownloadsEnabled = false
    @Published public private(set) var lastUpdateCheckDate: Date?

    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []

    public init() {}

    public func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == ArcKitConstants.appBundleIdentifier,
              !CommandLine.arguments.contains("--ui-debug"),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticChecksEnabled = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticDownloadsEnabled = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &subscriptions)
        isAvailable = true
        controller.startUpdater()
    }

    public func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
    }

    public func setAutomaticDownloadsEnabled(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticDownloadsEnabled = enabled
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
