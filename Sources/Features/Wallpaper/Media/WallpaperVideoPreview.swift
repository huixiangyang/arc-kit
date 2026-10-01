import ArcKitPlatform
import AVKit
import SwiftUI

/// 仅选中的资源创建播放器，滚动目录不会同时解码几十段视频。
struct WallpaperVideoPreview: View {
    let url: URL?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var error: String?
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
            if let player { VideoPlayer(player: player) }
            else { Text(url == nil ? L10n.string(.WallpaperMedia.previewPreviewVideoProvidedSourceMissing) : L10n.string(.WallpaperMedia.previewPreparingPreview)).foregroundStyle(.white.opacity(0.7)) }
            if let error { Text(error).font(.caption).foregroundStyle(.white).padding().background(.black.opacity(0.7)) }
        }
        .task(id: url) {
            // 同一详情切换资源时先释放旧队列，错误状态也随资源一起重置。
            releasePlayer()
            error = nil
            guard let url, WallpaperRemoteAccess.valid(url) || url.isFileURL else { return }
            let video = AVQueuePlayer(); video.isMuted = true; video.preventsDisplaySleepDuringVideoPlayback = false
            player = video
            let loop = AVPlayerLooper(player: video, templateItem: AVPlayerItem(url: url)); looper = loop
            video.play()
            do {
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(150))
                    if video.currentItem?.status == .readyToPlay { return }
                    if video.status == .failed || loop.status == .failed || video.currentItem?.status == .failed { break }
                }
                guard player === video else { return }
                error = L10n.string(.WallpaperMedia.previewUnavailableHint)
                video.pause()
            } catch { video.pause() }
        }
        .onDisappear(perform: releasePlayer)
    }

    private func releasePlayer() {
        player?.pause(); looper?.disableLooping(); player?.removeAllItems()
        player = nil; looper = nil
    }
}
