import ArcKitPlatform
import Foundation

/// 来源适配器共用元数据读取与地址规则，大素材由独立下载任务直接写盘。
enum WallpaperRemoteAccess {
    /// 内容按流读取并限制体积；无 Content-Length 的响应也不能无限占用内存。
    static func fetch(_ url: URL, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard valid(url) else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceEnterHttpsUrlWithoutAccountCredentials)) }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("ArcKit/0.1 (macOS wallpaper library)", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard let finalURL = response.url, valid(finalURL) else { throw WallpaperError.message(L10n.string(.WallpaperMedia.remoteRedirectRejected)) }
        guard (200..<300).contains(http.statusCode) else {
            let explanation = http.statusCode == 429 ? L10n.string(.WallpaperMedia.remoteTooManyRequestsRetryLater)
                : L10n.string(.WallpaperMedia.remoteSourceReturnedHttpRetryDisable(String(describing: http.statusCode)))
            throw WallpaperError.message(explanation)
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw WallpaperError.message(L10n.string(.WallpaperMedia.remoteSourceCatalogExceedsLimit(String(describing: L10n.fileSize(Int64(maximumBytes))))))
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in stream {
            guard data.count < maximumBytes else { throw WallpaperError.message(L10n.string(.WallpaperMedia.remoteSourceResponseExceedsSizeLimit)) }
            data.append(byte)
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
        }
        return (data, http)
    }

    static func valid(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

}
