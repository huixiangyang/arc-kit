import AppKit
import AVFoundation
import SwiftUI

private struct AppBackgroundVisibleKey: EnvironmentKey { static let defaultValue = false }
private struct AppBackgroundReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct AppBackgroundWindowVisibleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var appBackgroundVisible: Bool {
        get { self[AppBackgroundVisibleKey.self] }
        set { self[AppBackgroundVisibleKey.self] = newValue }
    }
    var appBackgroundReduceMotion: Bool {
        get { self[AppBackgroundReduceMotionKey.self] }
        set { self[AppBackgroundReduceMotionKey.self] = newValue }
    }
    var appBackgroundWindowVisible: Bool {
        get { self[AppBackgroundWindowVisibleKey.self] }
        set { self[AppBackgroundWindowVisibleKey.self] = newValue }
    }
}

/// 原生 Form / List 只隐藏滚动底色，保留系统行背景与交互，避免图片降低控件可读性。
private struct AppBackgroundSurface: ViewModifier {
    @Environment(\.appBackgroundVisible) private var enabled
    func body(content: Content) -> some View {
        content.scrollContentBackground(enabled ? .hidden : .automatic)
    }
}
extension View {
    func appBackgroundSurface() -> some View { modifier(AppBackgroundSurface()) }
    func appBackgroundWindowChrome() -> some View { modifier(AppBackgroundWindowChrome()) }
}

/// 工具栏与 AppKit 标题栏各有一层底色，需同时隐藏，才能显示延伸到顶部的背景。
private struct AppBackgroundWindowChrome: ViewModifier {
    @Environment(\.appBackgroundVisible) private var enabled
    func body(content: Content) -> some View {
        content
            .toolbarBackground(enabled ? .hidden : .automatic, for: .windowToolbar)
            .background { BackgroundWindowBridge(enabled: enabled).frame(width: 0, height: 0) }
    }
}

private struct BackgroundWindowBridge: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> BackgroundWindowView { BackgroundWindowView() }
    func updateNSView(_ view: BackgroundWindowView, context: Context) {
        view.enabled = enabled
        view.applyAppearance()
    }
    static func dismantleNSView(_ view: BackgroundWindowView, coordinator: ()) { view.restoreAppearance() }
}

private final class BackgroundWindowView: NSView {
    var enabled = false
    private weak var styledWindow: NSWindow?
    private var originalTransparency = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== styledWindow {
            restoreAppearance()
            styledWindow = window
            originalTransparency = window?.titlebarAppearsTransparent ?? false
        }
        applyAppearance()
    }

    func applyAppearance() {
        // 系统背景和“减少透明度”都恢复原生标题栏；不重建窗口或改变标题栏按钮。
        let transparent = enabled || originalTransparency
        if styledWindow?.titlebarAppearsTransparent != transparent {
            styledWindow?.titlebarAppearsTransparent = transparent
        }
    }

    func restoreAppearance() {
        styledWindow?.titlebarAppearsTransparent = originalTransparency
        styledWindow = nil
    }
}

/// 两列裁切包含标题栏的同一画布；只让背景越过安全区，前景仍使用系统布局。
struct AppBackgroundSlice: View {
    @ObservedObject var model: AppBackgroundModel
    let canvasFrame: CGRect
    @Environment(\.appBackgroundVisible) private var enabled
    var body: some View {
        if enabled {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("ArcKitAppBackground"))
                AppBackgroundCanvas(settings: model.settings, image: model.image, videoURL: model.videoURL, clock: model.playback)
                    .frame(width: canvasFrame.width, height: canvasFrame.height)
                    // 用完整画布与切片的原点差裁切，标题栏和底边都保持连续。
                    .offset(x: canvasFrame.minX - frame.minX, y: canvasFrame.minY - frame.minY)
            }
            .clipped()
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct AppBackgroundCanvas: View {
    let settings: AppBackgroundSettings
    let image: NSImage?
    var videoURL: URL? = nil
    var clock: AuraPlaybackClock? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appBackgroundReduceMotion) private var appReduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.appBackgroundWindowVisible) private var windowVisible

    private var videoPlays: Bool {
        windowVisible && !reduceMotion && !appReduceMotion && activeState != .inactive
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if settings.style == .aura && reduceTransparency {
                    Color(auraRGB: (scheme == .dark ? settings.aura.resolved(in: settings.themes, dark: true).dark[0] : settings.aura.resolved(in: settings.themes, dark: false).light[0]))
                }
                if settings.style != .system && !reduceTransparency {
                    if settings.style == .image || settings.style == .video, let image {
                        ZStack {
                            Image(nsImage: image).resizable().scaledToFill()
                            if settings.style == .video, let videoURL {
                                AppBackgroundVideo(url: videoURL, paused: !videoPlays)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        // 封面和视频先合成，再统一应用效果，避免双层透明度叠加改变明暗。
                        .compositingGroup()
                        .scaleEffect(1 + settings.blur * 2 / max(1, min(proxy.size.width, proxy.size.height)))
                        .blur(radius: settings.blur)
                        .opacity(settings.opacity)
                    }
                    if settings.style == .aura || image == nil {
                        if let clock { AuraWindowCanvas(settings: settings, clock: clock) }
                        else { AuraArtwork(theme: settings.aura.resolved(in: settings.themes, dark: scheme == .dark), intensity: settings.opacity,
                                           particles: settings.aura.resolved(in: settings.themes, dark: scheme == .dark).particles,
                                           grain: settings.aura.resolved(in: settings.themes, dark: scheme == .dark).grain) }
                    }
                    (scheme == .dark ? Color.black : Color.white)
                        .opacity(max(settings.dimming, contrast == .increased ? 0.6 : 0))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

/// 每个窗口切片持有自己的渲染层；隐藏、减少动态效果和失去活动状态时暂停解码。
private struct AppBackgroundVideo: NSViewRepresentable {
    let url: URL
    let paused: Bool
    func makeNSView(context: Context) -> BackgroundVideoView { BackgroundVideoView() }
    func updateNSView(_ view: BackgroundVideoView, context: Context) { view.update(url: url, paused: paused) }
    static func dismantleNSView(_ view: BackgroundVideoView, coordinator: ()) { view.stop() }
}
private final class BackgroundVideoView: NSView {
    private let videoLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var url: URL?
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; videoLayer.videoGravity = .resizeAspectFill }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { videoLayer }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player?.pause() }
    }
    func update(url: URL, paused: Bool) {
        if self.url != url {
            stop(); self.url = url
            let player = AVQueuePlayer(); player.isMuted = true; player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            videoLayer.player = player
        }
        if paused { player?.pause() } else { player?.play() }
    }
    func stop() { player?.pause(); looper?.disableLooping(); player?.removeAllItems(); videoLayer.player = nil; player = nil; looper = nil; url = nil }
}
