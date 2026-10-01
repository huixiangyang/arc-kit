import ArcKitPlatform
import Foundation

struct WallpaperOnlineSource: Sendable {
    static func search(provider: WallpaperProvider, query: String, page: Int) async throws -> WallpaperSearchPage {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        let endpoint: String
        switch provider {
        case .wallhaven: endpoint = "https://wallhaven.cc/api/v1/search"
        case .commons: endpoint = "https://commons.wikimedia.org/w/api.php"
        case .bing: endpoint = "https://www.bing.com/HPImageArchive.aspx"
        case .picsum: endpoint = "https://picsum.photos/v2/list"
        }
        var components = URLComponents(string: endpoint)!
        switch provider {
        case .wallhaven:
            components.queryItems = [
                .init(name: "q", value: term.isEmpty ? "landscape" : term),
                .init(name: "purity", value: "100"), .init(name: "categories", value: "100"),
                .init(name: "sorting", value: term.isEmpty ? "toplist" : "relevance"),
                .init(name: "page", value: String(page))
            ]
        case .commons:
            components.queryItems = [
                .init(name: "action", value: "query"), .init(name: "format", value: "json"),
                .init(name: "formatversion", value: "2"), .init(name: "generator", value: "search"),
                .init(name: "gsrnamespace", value: "6"), .init(name: "gsrlimit", value: "24"),
                .init(name: "gsroffset", value: String((page - 1) * 24)),
                .init(name: "gsrsearch", value: "\(term.isEmpty ? "landscape" : term) filetype:bitmap"),
                .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|size|mime|extmetadata"),
                .init(name: "iiurlwidth", value: "480")
            ]
        case .bing:
            components.queryItems = [.init(name: "format", value: "js"), .init(name: "idx", value: "0"),
                .init(name: "n", value: "8"), .init(name: "mkt", value: L10n.language.resolved() == .simplifiedChinese ? "zh-CN" : "en-US")]
        case .picsum:
            components.queryItems = [.init(name: "page", value: String(page)), .init(name: "limit", value: "24")]
        }
        let (data, _) = try await WallpaperRemoteAccess.fetch(components.url!, maximumBytes: 4 * 1_024 * 1_024)
        return try decode(data, provider: provider)
    }

    static func decode(_ data: Data, provider: WallpaperProvider) throws -> WallpaperSearchPage {
        let decoder = JSONDecoder()
        switch provider {
        case .bing:
            let response = try decoder.decode(BingResponse.self, from: data)
            let items = response.images.compactMap { entry -> OnlineWallpaper? in
                guard let url = URL(string: entry.url, relativeTo: URL(string: "https://www.bing.com"))?.absoluteURL,
                      WallpaperRemoteAccess.valid(url) else { return nil }
                let page = entry.copyrightlink.flatMap(URL.init(string:)) ?? URL(string: "https://www.bing.com")!
                return OnlineWallpaper(id: "bing-\(entry.startdate)", title: entry.title ?? entry.copyright,
                    imageURL: url, thumbnailURL: url, width: 1920, height: 1080,
                    origin: WallpaperOrigin(provider: provider.rawValue, pageURL: page,
                        author: entry.copyright, license: L10n.string(.WallpaperSources.onlineSourceSeeSourcePageBingImage)))
            }
            return WallpaperSearchPage(items: items, hasNextPage: false)
        case .picsum:
            let response = try decoder.decode([PicsumEntry].self, from: data)
            let items = response.compactMap { entry -> OnlineWallpaper? in
                guard WallpaperRemoteAccess.valid(entry.download_url), WallpaperRemoteAccess.valid(entry.url), Int(entry.id) != nil,
                      let thumbnail = URL(string: "https://picsum.photos/id/\(entry.id)/480/300") else { return nil }
                return OnlineWallpaper(id: "picsum-\(entry.id)", title: "\(entry.author) · \(entry.id)", imageURL: entry.download_url,
                    thumbnailURL: thumbnail, width: entry.width, height: entry.height,
                    origin: WallpaperOrigin(provider: provider.rawValue, pageURL: entry.url, author: entry.author, license: L10n.string(.WallpaperSources.onlineSourceSeeSourcePageUsageTerms)))
            }
            return WallpaperSearchPage(items: items, hasNextPage: response.count == 24)
        case .wallhaven:
            let response = try decoder.decode(WallhavenResponse.self, from: data)
            let items = response.data.filter { $0.purity == "sfw" }.compactMap { item -> OnlineWallpaper? in
                guard WallpaperRemoteAccess.valid(item.path), WallpaperRemoteAccess.valid(item.url), WallpaperRemoteAccess.valid(item.thumbs.large) else { return nil }
                return OnlineWallpaper(id: "wallhaven-\(item.id)", title: "Wallhaven · \(item.id)",
                    imageURL: item.path, thumbnailURL: item.thumbs.large, width: item.dimension_x, height: item.dimension_y,
                    origin: WallpaperOrigin(provider: provider.rawValue, pageURL: item.url, license: L10n.string(.WallpaperSources.onlineSourceSeeOriginalImagePageUsage)))
            }
            return WallpaperSearchPage(items: items, hasNextPage: response.meta.current_page < response.meta.last_page)
        case .commons:
            let response = try decoder.decode(CommonsResponse.self, from: data)
            if let error = response.error { throw WallpaperError.message(error.info) }
            let items = (response.query?.pages ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }.compactMap { page -> OnlineWallpaper? in
                guard let info = page.imageinfo?.first, ["image/jpeg", "image/png", "image/webp", "image/tiff"].contains(info.mime),
                      let thumbnail = info.thumburl, WallpaperRemoteAccess.valid(info.url), WallpaperRemoteAccess.valid(thumbnail), WallpaperRemoteAccess.valid(info.descriptionurl) else { return nil }
                return OnlineWallpaper(id: "commons-\(page.pageid)", title: String(page.title.dropFirst(5)),
                    imageURL: info.url, thumbnailURL: thumbnail, width: info.width, height: info.height,
                    origin: WallpaperOrigin(provider: provider.rawValue, pageURL: info.descriptionurl,
                        author: info.extmetadata?["Artist"].map { plainText($0.value) },
                        license: info.extmetadata?["LicenseShortName"].map { plainText($0.value) }))
            }
            return WallpaperSearchPage(items: items, hasNextPage: response.continuation != nil)
        }
    }

    private static func plainText(_ value: String) -> String {
        String(value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").prefix(400))
    }
}

private struct BingResponse: Decodable {
    struct Entry: Decodable {
        let startdate: String
        let url: String
        let title: String?
        let copyright: String
        let copyrightlink: String?
    }
    let images: [Entry]
}

private struct PicsumEntry: Decodable {
    let id: String
    let author: String
    let width: Int
    let height: Int
    let url: URL
    let download_url: URL
}

private struct WallhavenResponse: Decodable {
    struct Entry: Decodable {
        struct Thumbs: Decodable { let large: URL }
        let id: String
        let url: URL
        let path: URL
        let purity: String
        let dimension_x: Int
        let dimension_y: Int
        let thumbs: Thumbs
    }
    struct Meta: Decodable { let current_page: Int; let last_page: Int }
    let data: [Entry]
    let meta: Meta
}

private struct CommonsResponse: Decodable {
    struct APIError: Decodable { let info: String }
    struct Metadata: Decodable {
        let value: String
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            // Commons 的扩展元数据同时包含字符串和版本号；只展示文字归属信息。
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? container.decode(String.self, forKey: .value)) ?? ""
        }
    }
    struct Info: Decodable {
        let url: URL
        let thumburl: URL?
        let descriptionurl: URL
        let width: Int
        let height: Int
        let mime: String
        let extmetadata: [String: Metadata]?
    }
    struct Page: Decodable { let pageid: Int; let title: String; let index: Int?; let imageinfo: [Info]? }
    struct Query: Decodable { let pages: [Page] }
    struct Continuation: Decodable { let gsroffset: Int? }
    let query: Query?
    let error: APIError?
    let continuation: Continuation?
    enum CodingKeys: String, CodingKey { case query, error; case continuation = "continue" }
}
