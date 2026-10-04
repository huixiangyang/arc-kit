import ArcKitPlatform
import AVFoundation
import Foundation

/// 原生静音循环与播放生命周期，不创建窗口；桌面 session 负责把 player 接到画面。
@MainActor
final class WallpaperVideoPlayback {
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private(set) var state: WallpaperVideoPlaybackState
    private var failureMessage: String?
    private var playerObservation: NSKeyValueObservation?
    private var looperObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private weak var observedItem: AVPlayerItem?
    private var endFailureObserver: NSObjectProtocol?
    var failed: ((String) -> Void)?

    init(url: URL, paused: Bool) {
        state = WallpaperVideoPlaybackState(paused: paused)
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            let message = player.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed)
            Task { @MainActor [weak self] in self?.fail(message) }
        }
        looperObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let message = looper.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed)
            Task { @MainActor [weak self] in self?.fail(message) }
        }
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeCurrentItem() }
        }
        observeCurrentItem()
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            try checkPlaybackFailure()
            if player.currentItem?.status == .readyToPlay { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopVideoLoadingTimeoutOriginalWallpaper))
    }

    func checkPlaybackFailure() throws {
        if state.phase == .closed { throw CancellationError() }
        if let failureMessage { throw WallpaperError.message(failureMessage) }
        if player.status == .failed || player.currentItem?.status == .failed || looper.status == .failed {
            throw WallpaperError.message(player.currentItem?.error?.localizedDescription ?? looper.error?.localizedDescription
                ?? player.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopPlaybackFailed))
        }
    }

    private func observeCurrentItem() {
        guard state.phase != .closed, state.phase != .failed else { return }
        let item = player.currentItem
        guard observedItem !== item else { return }
        itemObservation = nil
        if let endFailureObserver { NotificationCenter.default.removeObserver(endFailureObserver) }
        endFailureObserver = nil
        observedItem = item
        guard let item else { return }
        // AVPlayerLooper 会替换当前 item；每一轮都更新观察，旧 item 的观察及时释放。
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let itemID = ObjectIdentifier(item)
            let message = item.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed)
            Task { @MainActor [weak self] in self?.fail(message, itemID: itemID) }
        }
        let itemID = ObjectIdentifier(item)
        endFailureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed)
            Task { @MainActor [weak self] in self?.fail(message, itemID: itemID) }
        }
    }

    func show(paused: Bool) throws {
        try checkPlaybackFailure()
        guard state.show(paused: paused) else {
            throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed))
        }
        updatePlayback()
    }
    func hide() { state.hide(); updatePlayback() }
    func setPaused(_ paused: Bool) { state.setPaused(paused); updatePlayback() }

    private func updatePlayback() { if state.shouldPlay { player.play() } else { player.pause() } }

    private func fail(_ message: String, itemID: ObjectIdentifier? = nil) {
        // 局部 item 回调跨 actor 投递后只处理当前项；Looper 的整体失败仍必须收敛。
        // 已播放的 item 可能仍在循环队列中，不能把它引起的 Looper 失败当作过期通知。
        if let itemID {
            guard let current = player.currentItem, ObjectIdentifier(current) == itemID else { return }
        }
        guard state.fail() else { return }
        failureMessage = message
        releasePlayback()
        failed?(message)
    }

    func close() {
        guard state.close() else { return }
        failed = nil
        releasePlayback()
    }

    private func releasePlayback() {
        playerObservation = nil; looperObservation = nil; currentItemObservation = nil; itemObservation = nil
        if let endFailureObserver { NotificationCenter.default.removeObserver(endFailureObserver) }
        endFailureObserver = nil; observedItem = nil
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
    }
}

/// 暂停不撤下画面，隐藏和终态则不能被恢复播放唤醒。
struct WallpaperVideoPlaybackState {
    enum Phase { case hidden, presented, failed, closed }

    private(set) var phase: Phase = .hidden
    private(set) var isPaused: Bool
    var isPresented: Bool { phase == .presented }
    var shouldPlay: Bool { isPresented && !isPaused }

    init(paused: Bool) { isPaused = paused }

    @discardableResult
    mutating func show(paused: Bool) -> Bool {
        guard phase != .failed, phase != .closed else { return false }
        isPaused = paused
        phase = .presented
        return true
    }

    mutating func hide() { if phase == .presented { phase = .hidden } }
    mutating func setPaused(_ paused: Bool) { isPaused = paused }

    /// 多个播放器观察源可能同时失败，只允许第一个发布回执。
    @discardableResult
    mutating func fail() -> Bool {
        guard phase != .failed, phase != .closed else { return false }
        phase = .failed
        return true
    }

    @discardableResult
    mutating func close() -> Bool {
        guard phase != .closed else { return false }
        phase = .closed
        return true
    }
}
