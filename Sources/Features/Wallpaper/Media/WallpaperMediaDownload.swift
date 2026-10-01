import ArcKitPlatform
import Foundation
import UniformTypeIdentifiers

/// URLSession 直接写临时文件，图片和视频都不整份读进内存。delegate 状态全部由 lock 保护。
final class WallpaperMediaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var failure: (any Error)?
    private var output: URL?
    private var lastProgressTime = Date.distantPast
    private let title: String
    private let progress: @Sendable (Int64, Int64) -> Void
    private let kind: WallpaperKind
    private var limit: Int64 { (kind == .image ? 100 : 512) * 1_024 * 1_024 }

    private init(title: String, kind: WallpaperKind, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.title = title; self.kind = kind; self.progress = progress
    }
    static func download(_ url: URL, title: String, kind: WallpaperKind, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard WallpaperRemoteAccess.valid(url) else { throw WallpaperError.message(L10n.string(.WallpaperMedia.downloadWallpaperAssetsUseHttpsUrls)) }
        let operation = WallpaperMediaDownload(title: title, kind: kind, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start(url, continuation: $0) }
        } onCancel: { operation.cancel() }
    }
    private func start(_ url: URL, continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("ArcKit/0.1 (macOS wallpaper library)", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(WallpaperRemoteAccess.valid) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            lock.lock(); failure = WallpaperError.message(L10n.string(.WallpaperMedia.downloadDownloadExceedsMbLimitChoose(String(describing: limit / 1_024 / 1_024)))); lock.unlock()
            downloadTask.cancel(); return
        }
        lock.lock()
        let now = Date()
        let report = now.timeIntervalSince(lastProgressTime) >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite
        if report { lastProgressTime = now }
        lock.unlock()
        if report { progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let url = response.url, WallpaperRemoteAccess.valid(url) else {
                throw WallpaperError.message(L10n.string(.WallpaperMedia.downloadDownloadSourceReturnedHttpFailed(String(describing: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))))
            }
            let ext = try Self.fileExtension(response, kind: kind)
            let bytes = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= limit else { throw WallpaperError.message(L10n.string(.WallpaperMedia.downloadAssetEmptyExceedsMb(String(describing: limit / 1_024 / 1_024)))) }
            let folder = try ArcKitStoragePaths.current.makeTemporaryDirectory()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = String(title.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted).joined().prefix(80))
            let file = folder.appendingPathComponent("\(name.isEmpty ? L10n.string(.WallpaperMedia.downloadOnlineWallpaper) : name).\(ext)")
            do { try FileManager.default.moveItem(at: location, to: file) }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
            lock.lock(); output = file; lock.unlock()
        } catch { lock.lock(); failure = error; lock.unlock() }
    }
    static func fileExtension(_ response: HTTPURLResponse, kind: WallpaperKind) throws -> String {
        let allowed = kind == .image ? ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"] : ["mp4", "mov", "m4v"]
        let mime = response.mimeType?.lowercased()
        let ext: String?
        if mime == nil || mime == "application/octet-stream" {
            ext = URL(fileURLWithPath: response.suggestedFilename ?? response.url?.lastPathComponent ?? "").pathExtension.lowercased()
        } else if let mime, let type = UTType(mimeType: mime), type.conforms(to: kind == .image ? .image : .movie) {
            ext = type.preferredFilenameExtension
        } else { ext = nil }
        guard let ext, allowed.contains(ext) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.downloadUnsupportedMedia(String(describing: kind == .image ? L10n.string(.AppBackground.backgroundStorageImage) : L10n.string(.AppBackground.backgroundStorageVideo)))))
        }
        return ext
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let file = output
        let resultError = cancelled ? CancellationError() : (failure ?? error)
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let resultError {
            if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            continuation?.resume(throwing: resultError)
        } else if let file { continuation?.resume(returning: file) }
        else { continuation?.resume(throwing: URLError(.cannotCreateFile)) }
    }
}
