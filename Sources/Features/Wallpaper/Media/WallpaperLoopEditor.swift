import ArcKitPlatform
import AVFoundation
import AVKit
import SwiftUI

struct WallpaperVideoEditing {
    static func validate(start: Double, end: Double, speed: Double, duration: Double) throws {
        guard start.isFinite, end.isFinite, speed.isFinite, duration.isFinite,
              start >= 0, end <= duration + 0.01, end - start >= 0.3, end - start <= 300,
              (0.25...2).contains(speed) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.loopInvalidSegment))
        }
    }
    static func export(url: URL, start: Double, end: Double, speed: Double, title: String? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        try validate(start: start, end: end, speed: speed, duration: duration)
        guard let original = try await asset.loadTracks(withMediaType: .video).first else { throw WallpaperError.message(L10n.string(.WallpaperMedia.loopVideoVideoTrackMissing)) }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.loopTrackCreationFailed))
        }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        try track.insertTimeRange(range, of: original, at: .zero)
        track.preferredTransform = try await original.load(.preferredTransform)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: CMTime(seconds: (end - start) / speed, preferredTimescale: 600))
        // 壁纸不导出音轨；保留原文件，输出独立且可离线播放的 MP4。
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw WallpaperError.message(L10n.string(.WallpaperMedia.loopExportUnavailable)) }
        let folder = try ArcKitStoragePaths.current.makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (title ?? url.deletingPathExtension().lastPathComponent)
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted).joined()
        let file = folder.appendingPathComponent(L10n.string(.WallpaperMedia.loopLoopMp4(String(describing: name.prefix(60)))))
        var completed = false
        defer { if !completed { exporter.cancelExport(); try? FileManager.default.removeItem(at: folder) } }
        exporter.outputURL = file; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously(completionHandler: {})
        while exporter.status == .waiting || exporter.status == .exporting || exporter.status == .unknown {
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? WallpaperError.message(L10n.string(.WallpaperMedia.loopLoopExportFailed)) }
        completed = true
        return file
    }
}

struct WallpaperLoopEditor: View {
    let item: WallpaperItem
    let url: URL
    let save: (Double, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var speed = 1.0
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var error: String?
    @State private var ready = false
    private var valid: Bool { (try? WallpaperVideoEditing.validate(start: start, end: end, speed: speed, duration: duration)) != nil }
    var body: some View {
        WallpaperDetailPanel(title: L10n.string(.WallpaperMedia.loopEditLoop), subtitle: item.name) {
            VideoPlayer(player: player).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
            if ready {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text(L10n.string(.WallpaperMedia.loopStart)).frame(width: 40, alignment: .leading)
                        Slider(value: $start, in: 0...max(0.01, duration - 0.3), step: 0.1) { Text(L10n.string(.WallpaperMedia.loopLoopStart)) }.labelsHidden()
                        Text("\(start, specifier: "%.1f") s").monospacedDigit().frame(width: 65, alignment: .trailing)
                    }
                    HStack(spacing: 12) {
                        Text(L10n.string(.WallpaperMedia.loopEnd)).frame(width: 40, alignment: .leading)
                        Slider(value: $end, in: 0.3...max(0.31, duration), step: 0.1) { Text(L10n.string(.WallpaperMedia.loopLoopEnd)) }.labelsHidden()
                        Text("\(end, specifier: "%.1f") s").monospacedDigit().frame(width: 65, alignment: .trailing)
                    }
                    Picker(L10n.string(.WallpaperMedia.loopSpeed), selection: $speed) {
                        ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                    }.pickerStyle(.segmented)
                }
            } else if error == nil { ProgressView(L10n.string(.WallpaperMedia.loopReadingVideo)).controlSize(.small) }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            Text(L10n.string(.WallpaperMedia.loopAdjustingClickPreviewLoopCheck))
                .font(.caption).foregroundStyle(.secondary)
        } actions: {
            HStack(spacing: 10) {
                Button(L10n.string(.WallpaperMedia.loopPreviewLoop), action: preview).disabled(!ready || !valid)
                if ready {
                    Text(valid ? L10n.string(.WallpaperMedia.loopOutputDuration((end - start) / speed)) : L10n.string(.WallpaperMedia.loopSegmentRange))
                        .font(.caption).foregroundStyle(valid ? Color.secondary : .orange)
                }
                Spacer(minLength: 0)
                Button(L10n.string(.WallpaperMedia.loopSaveNewWallpaper)) { save(start, end, speed); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!ready || !valid)
            }
        }
        .task {
            do {
                duration = try await AVURLAsset(url: url).load(.duration).seconds
                try Task.checkCancellation()
                guard duration.isFinite, duration >= 0.3 else { throw WallpaperError.message(L10n.string(.WallpaperMedia.loopVideoTooShort)) }
                end = min(duration, 30); ready = true; preview()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.pause(); looper?.disableLooping(); player?.removeAllItems(); looper = nil; player = nil }
    }
    private func preview() {
        guard valid else { return }
        player?.pause(); looper?.disableLooping()
        let video = AVQueuePlayer(); video.isMuted = true; video.preventsDisplaySleepDuringVideoPlayback = false
        video.defaultRate = Float(speed)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        looper = AVPlayerLooper(player: video, templateItem: AVPlayerItem(url: url), timeRange: range)
        player = video; video.playImmediately(atRate: Float(speed))
    }
}
