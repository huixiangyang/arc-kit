@testable import ArcKitApplication
@preconcurrency import AVFoundation
import AVKit
import Foundation
import Testing

@Suite("壁纸原生播放", .serialized)
struct WallpaperPlaybackTests {
    @Test("真实循环播放器继承暂停，隐藏不恢复，换轮失败只回执一次并释放队列")
    @MainActor
    func nativePlaybackLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArcKit-PlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await videoFixture(in: directory)
        let playback = WallpaperVideoPlayback(url: source, paused: true)
        defer { playback.close() }
        // 离屏实例化 AVKit，覆盖真实播放器连接；不创建或显示 NSWindow，不触及桌面。
        let view = AVPlayerView(frame: CGRect(x: 0, y: 0, width: 32, height: 24))
        view.controlsStyle = .none
        view.player = playback.player
        defer { view.player = nil }
        #expect(view.player === playback.player)
        #expect(playback.player.isMuted && !playback.player.preventsDisplaySleepDuringVideoPlayback)

        try await playback.waitUntilReady()
        try playback.show(paused: true)
        #expect(playback.state.isPresented && !playback.state.shouldPlay)
        #expect(playback.player.rate == 0)
        let first = try #require(playback.player.currentItem)
        playback.setPaused(false)
        // 让短片真实播放至下一轮，随后向新 item 发出失败，验证观察跟随循环换项。
        for _ in 0..<250 where playback.player.currentItem === first {
            try await Task.sleep(for: .milliseconds(20))
        }
        let next = try #require(playback.player.currentItem)
        try #require(next !== first)
        playback.hide()
        playback.setPaused(false)
        #expect(!playback.state.isPresented && !playback.state.shouldPlay && playback.player.rate == 0)
        // 等待本轮 currentItem KVO 已投递到主 actor；保持隐藏，队列不会再换项。
        try await Task.sleep(for: .milliseconds(20))

        var failures: [String] = []
        playback.failed = { failures.append($0) }
        let failure = NSError(domain: "ArcKit.PlaybackFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture playback failed"])
        // 旧轮 item 仍归 Looper 队列所有，其失败会使整个循环失败；用独立 item 验证隔离。
        let unrelated = AVPlayerItem(url: source)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: unrelated, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: failure])
        await Task.yield()
        #expect(failures.isEmpty && playback.state.phase == .hidden)
        for _ in 0..<2 {
            NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: next, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: failure])
        }
        for _ in 0..<100 where failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(failures == [failure.localizedDescription])
        #expect(playback.state.phase == .failed && playback.player.rate == 0 && playback.player.items().isEmpty)
        playback.setPaused(false)
        #expect(throws: (any Error).self) { try playback.show(paused: false) }
        #expect(playback.player.rate == 0)
        playback.close()
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: next)
        await Task.yield()
        #expect(failures.count == 1 && playback.state.phase == .closed && playback.player.items().isEmpty)

        // 正常关闭也释放解码队列，而不只覆盖失败后的空队列。
        let stopped = WallpaperVideoPlayback(url: source, paused: true)
        defer { stopped.close() }
        try await stopped.waitUntilReady()
        #expect(!stopped.player.items().isEmpty)
        stopped.close()
        stopped.setPaused(false)
        #expect(throws: (any Error).self) { try stopped.show(paused: false) }
        #expect(stopped.player.items().isEmpty && stopped.player.rate == 0)
    }

    private func videoFixture(in directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("loop.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 24
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 24
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 32, 24, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 180, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<12 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            try #require(input.isReadyForMoreMediaData)
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return source
    }
}
