import ArcKitPlatform
import AppKit
import AVFoundation
import QuartzCore

@MainActor
struct WallpaperDesktopChange {
    let displayIDs: [String]
    let unconfirmedDisplayIDs: Set<String>
    let commit: () -> Void
    let rollback: () async throws -> Void
}

@MainActor
protocol WallpaperDesktopHandling: AnyObject {
    var displays: [WallpaperDisplay] { get }
    func apply(_ item: WallpaperItem, url: URL, request: WallpaperDesktopRequest) async throws -> WallpaperDesktopChange
    func isShowing(_ item: WallpaperItem, url: URL, on displayID: String) -> Bool
    func stopVideos()
    func pauseVideos(_ paused: Bool)
    func discardDisconnectedDisplays()
}

/// 借鉴 Arc Wallpaper 的稳定 UUID、写前快照与读回校验；所有桌面写入均在主线程串行执行。
@MainActor
final class WallpaperDesktop: WallpaperDesktopHandling {
    private var videos: [String: WallpaperVideoSession] = [:]
    private let isPreview: Bool
    var playbackFailed: ((String) -> Void)?

    init(isPreview: Bool = false) { self.isPreview = isPreview }

    private var screens: [(id: String, screen: NSScreen)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let value = CFUUIDCreateString(nil, uuid) else { return nil }
            return (value as String, screen)
        }
    }

    var displays: [WallpaperDisplay] {
        screens.enumerated().map { index, value in
            WallpaperDisplay(id: value.id, name: value.screen.localizedName,
                width: Int((value.screen.frame.width * value.screen.backingScaleFactor).rounded()),
                height: Int((value.screen.frame.height * value.screen.backingScaleFactor).rounded()),
                frame: value.screen.frame, isPrimary: index == 0)
        }
    }

    func isShowing(_ item: WallpaperItem, url: URL, on displayID: String) -> Bool {
        if item.kind == .video { return videos[displayID]?.isShowing(url) == true }
        guard videos[displayID] == nil, let screen = screens.first(where: { $0.id == displayID })?.screen else { return false }
        return WallpaperImageTransaction.matches(NSWorkspace.shared.desktopImageURL(for: screen), url)
    }

    func apply(_ item: WallpaperItem, url: URL, request: WallpaperDesktopRequest) async throws -> WallpaperDesktopChange {
        guard !isPreview else { throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopDebugScope)) }
        var targets = screens.filter { request.displayIDs.contains($0.id) }
        try request.validate(connected: Set(targets.map(\.id)))
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopUnreadableFile)) }
        let previousVideos = videos.filter { entry in targets.contains { $0.id == entry.key } }
        var prepared: [String: WallpaperVideoSession] = [:]
        var handedOff = false
        defer { if !handedOff { prepared.values.forEach { $0.close() } } }
        if item.kind == .video {
            for target in targets {
                let session = WallpaperVideoSession(url: url, screen: target.screen, scaling: request.scaling)
                do { try await session.waitUntilReady() }
                catch { session.close(); throw error }
                prepared[target.id] = session
            }
        }
        try Task.checkCancellation()
        // 视频准备会挂起；真正写入前重新读取拓扑，目标缺失则整次拒绝。
        targets = screens.filter { request.displayIDs.contains($0.id) }
        try request.validate(connected: Set(targets.map(\.id)))
        for target in targets { prepared[target.id]?.setFrame(target.screen.frame) }
        let imageTransaction: WallpaperImageTransaction? = item.kind == .image ? WallpaperImageTransaction(
            targets: displays.filter { request.displayIDs.contains($0.id) },
            access: WallpaperImageAccess(
                connectedIDs: { [self] in Set(screens.map(\.id)) },
                read: { [self] id in
                    guard let screen = screens.first(where: { $0.id == id })?.screen else { return .init(url: nil, options: [:]) }
                    return .init(url: NSWorkspace.shared.desktopImageURL(for: screen),
                        options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
                },
                write: { [self] id, url, options in
                    guard let screen = screens.first(where: { $0.id == id })?.screen else {
                        throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopTargetDisplayDisconnected))
                    }
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
                },
                isReadable: { FileManager.default.isReadableFile(atPath: $0.path) }
            )) : nil

        let rollback: () async throws -> Void = { [self] in
            let connected = Set(screens.map(\.id))
            for target in targets {
                if let current = videos.removeValue(forKey: target.id), current !== previousVideos[target.id] { current.close() }
            }
            for (id, session) in previousVideos {
                if connected.contains(id) { videos[id] = session; session.show() }
                else { session.close() }
            }
            try await imageTransaction?.rollback()
        }
        do {
            let unconfirmed = try await imageTransaction?.apply(url, options: Self.options(request.scaling)) ?? []
            try Task.checkCancellation()
            try request.validate(connected: Set(screens.map(\.id)))
            for target in targets {
                videos.removeValue(forKey: target.id)?.hide()
                if let session = prepared[target.id] {
                    session.failed = { [weak self] message in self?.playbackFailed?(message) }
                    videos[target.id] = session
                    session.show()
                }
            }
            handedOff = true
            return WallpaperDesktopChange(displayIDs: targets.map(\.id), unconfirmedDisplayIDs: unconfirmed,
                commit: { previousVideos.values.forEach { $0.close() } }, rollback: rollback)
        } catch {
            do { try await rollback() }
            catch let recoveryError {
                throw WallpaperError.message("\(error.localizedDescription)；\(recoveryError.localizedDescription)")
            }
            throw error
        }
    }

    private static func options(_ scaling: WallpaperScaling) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        [.imageScaling: scaling == .stretch ? NSImageScaling.scaleAxesIndependently.rawValue : NSImageScaling.scaleProportionallyUpOrDown.rawValue,
         .allowClipping: scaling == .fill, .fillColor: NSColor.black]
    }

    func stopVideos() { videos.values.forEach { $0.close() }; videos.removeAll() }
    func pauseVideos(_ paused: Bool) { videos.values.forEach { $0.setPaused(paused) } }
    func discardDisconnectedDisplays() {
        let connected = Set(screens.map(\.id))
        for id in Array(videos.keys) where !connected.contains(id) { videos.removeValue(forKey: id)?.close() }
        for target in screens { videos[target.id]?.setFrame(target.screen.frame) }
    }
}

@MainActor
private final class WallpaperVideoSession {
    private let url: URL
    private let window: WallpaperVideoWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private var observation: NSKeyValueObservation?
    var failed: ((String) -> Void)?

    init(url: URL, screen: NSScreen, scaling: WallpaperScaling) {
        self.url = url
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        window = WallpaperVideoWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        let view = WallpaperVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : (scaling == .fit ? .resizeAspect : .resize)
        window.contentView = view
        observation = player.observe(\.status, options: [.new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            let message = player.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopVideoPlaybackFailed)
            Task { @MainActor [weak self] in self?.hide(); self?.failed?(message) }
        }
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if player.currentItem?.status == .readyToPlay { return }
            if player.status == .failed || player.currentItem?.status == .failed || looper.status == .failed {
                throw WallpaperError.message(player.currentItem?.error?.localizedDescription ?? L10n.string(.WallpaperPlayback.desktopPlaybackFailed))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WallpaperError.message(L10n.string(.WallpaperPlayback.desktopVideoLoadingTimeoutOriginalWallpaper))
    }

    func show() { window.orderBack(nil); player.play() }
    func isShowing(_ url: URL) -> Bool { self.url == url && window.isVisible }
    func hide() { player.pause(); window.orderOut(nil) }
    func setPaused(_ paused: Bool) { if paused { player.pause() } else { player.play() } }
    func setFrame(_ frame: NSRect) { window.setFrame(frame, display: true) }
    func close() { observation = nil; player.pause(); window.close() }
}

private final class WallpaperVideoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WallpaperVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    override func makeBackingLayer() -> CALayer { playerLayer }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
