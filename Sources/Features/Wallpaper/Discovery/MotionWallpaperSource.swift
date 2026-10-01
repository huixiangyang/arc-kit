import ArcKitPlatform
import Foundation

struct MotionVariant: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: URL
    var id: String { url.absoluteString }
}

struct MotionWallpaper: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var thumbnail: URL?
    var preview: URL?
    var origin: WallpaperOrigin
    var variants: [MotionVariant] = []
    var resolver: URL?
    var declaredQuality: WallpaperQuality?
    var quality: WallpaperQuality? {
        (variants.compactMap { WallpaperQuality.declared($0.title) } + [declaredQuality].compactMap { $0 }).max()
    }
}

struct WallpaperFeed: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var url: URL
    var id: String { url.absoluteString }
}

struct MotionWallpaperSource {
    static func isMotionPage(_ url: URL) -> Bool {
        ["motionbgs.com", "www.motionbgs.com", "moewalls.com", "www.moewalls.com"].contains(url.host?.lowercased() ?? "")
    }

    static func motion(category: String) async throws -> [MotionWallpaper] {
        let url = URL(string: "https://motionbgs.com/\(category)")!
        let (data, _) = try await WallpaperRemoteAccess.fetch(url, maximumBytes: 4_194_304)
        let items = decodeMotionList(String(decoding: data, as: UTF8.self), base: url)
        guard !items.isEmpty else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceSourcePageStructureChangedCatalog)) }
        return items
    }

    // HTML 只提取明确的资源字段，不执行网站脚本，也不推算下载地址。
    static func decodeMotionList(_ html: String, base: URL) -> [MotionWallpaper] {
        var seen = Set<String>()
        return matches(#"<a\b([^>]*)>([\s\S]*?)</a>"#, html).compactMap { match in
            guard let href = attribute("href", in: match[1]),
                  let page = URL(string: href, relativeTo: base)?.absoluteURL, WallpaperRemoteAccess.valid(page), isMotionPage(page),
                  let imageTag = matches(#"<img\b([^>]*)>"#, match[2]).first,
                  let src = attribute("src", in: imageTag[1]),
                  let thumb = URL(string: src, relativeTo: base)?.absoluteURL, WallpaperRemoteAccess.valid(thumb),
                  let title = attribute("title", in: match[1]), title.lowercased().contains("live wallpaper"),
                  seen.insert(page.absoluteString).inserted else { return nil }
            let quality = matches(#"<span\b([^>]*)>([\s\S]*?)</span>"#, match[2]).compactMap { tag -> WallpaperQuality? in
                guard attribute("class", in: tag[1])?.split(whereSeparator: \.isWhitespace).contains("frm") == true else { return nil }
                return WallpaperQuality.declared(plain(tag[2]))
            }.max()
            return MotionWallpaper(id: page.absoluteString, title: plain(title.replacingOccurrences(of: " live wallpaper", with: "", options: .caseInsensitive)),
                thumbnail: thumb, origin: WallpaperOrigin(provider: "MotionBGS", pageURL: page,
                    license: L10n.string(.WallpaperSources.motionSourceSeeSourcePageAttribution)), resolver: page, declaredQuality: quality)
        }
    }

    static func resolve(_ item: MotionWallpaper) async throws -> MotionWallpaper {
        guard let url = item.resolver else { return item }
        let (data, response) = try await WallpaperRemoteAccess.fetch(url, maximumBytes: 4_194_304)
        if isMotionPage(url) {
            guard let page = response.url, isMotionPage(page) else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceRedirectRejected)) }
            return try decodeMotionDetail(String(decoding: data, as: UTF8.self), page: page)
        }
        guard url.host == "images-assets.nasa.gov" else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceUnsupportedWebsite)) }
        let urls = try decodeNASAAssets(data)
        var result = item
        result.variants = urls.map { url in
            let name = url.deletingPathExtension().lastPathComponent.components(separatedBy: "~").last ?? L10n.string(.AppBackground.backgroundStorageVideo)
            return MotionVariant(title: ["orig": L10n.string(.WallpaperSources.motionSourceOriginalQuality), "large": L10n.string(.WallpaperSources.motionSourceHigh), "medium": L10n.string(.WallpaperSources.motionSourceStandard), "small": L10n.string(.WallpaperSources.motionSourceLow), "mobile": L10n.string(.WallpaperSources.motionSourceMobile), "preview": L10n.string(.WallpaperSources.motionSourcePreview)][name] ?? name, url: url)
        }
        guard !result.variants.isEmpty else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceMp4FileAvailableMissing)) }
        result.preview = urls.first(where: { $0.lastPathComponent.contains("~preview") })
            ?? urls.first(where: { $0.lastPathComponent.contains("~small") }) ?? urls.first
        result.resolver = nil
        return result
    }

    static func decodeMotionDetail(_ html: String, page: URL) throws -> MotionWallpaper {
        var metadata: [String: String] = [:]
        for tag in matches(#"<meta\b([^>]*)>"#, html) {
            if let key = attribute("property", in: tag[1]), let value = attribute("content", in: tag[1]) { metadata[key] = value }
        }
        var variants: [MotionVariant] = []
        for tag in matches(#"<a\b([^>]*)>([\s\S]*?)</a>"#, html) {
            guard let href = attribute("href", in: tag[1]), href.hasPrefix("/dl/"),
                  let url = URL(string: href, relativeTo: page)?.absoluteURL, WallpaperRemoteAccess.valid(url) else { continue }
            let label = plain(plain(tag[2]).replacingOccurrences(of: "Wallpaper", with: "").replacingOccurrences(of: "mp4 file", with: ""))
            variants.append(MotionVariant(title: label, url: url))
        }
        guard !variants.isEmpty else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourcePublicVideoDownloadLinkFoundMissing)) }
        return MotionWallpaper(id: page.absoluteString, title: plain(metadata["og:title"] ?? L10n.string(.WallpaperMedia.libraryLiveWallpaper)),
            thumbnail: metadata["og:image"].flatMap(URL.init(string:)).flatMap { WallpaperRemoteAccess.valid($0) ? $0 : nil },
            preview: metadata["og:video"].flatMap(URL.init(string:)).flatMap { WallpaperRemoteAccess.valid($0) ? $0 : nil },
            origin: WallpaperOrigin(provider: "MotionBGS", pageURL: page, license: L10n.string(.WallpaperSources.motionSourceSeeSourcePageAttribution)), variants: variants)
    }

    static func nasa(query: String, page: Int) async throws -> (items: [MotionWallpaper], more: Bool) {
        var url = URLComponents(string: "https://images-api.nasa.gov/search")!
        url.queryItems = [.init(name: "q", value: query.isEmpty ? "earth timelapse" : String(query.prefix(160))),
            .init(name: "media_type", value: "video"), .init(name: "page_size", value: "24"), .init(name: "page", value: String(page))]
        let (data, _) = try await WallpaperRemoteAccess.fetch(url.url!, maximumBytes: 4_194_304)
        return try decodeNASA(data)
    }

    static func decodeNASA(_ data: Data) throws -> (items: [MotionWallpaper], more: Bool) {
        let response = try JSONDecoder().decode(NASAResponse.self, from: data)
        let items = response.collection.items.compactMap { entry -> MotionWallpaper? in
            guard let info = entry.data.first, WallpaperRemoteAccess.valid(entry.href), entry.href.host == "images-assets.nasa.gov" else { return nil }
            let page = URL(string: "https://images.nasa.gov/details")!.appendingPathComponent(info.nasa_id)
            return MotionWallpaper(id: "nasa-\(info.nasa_id)", title: info.title,
                thumbnail: entry.links?.first(where: { $0.rel == "preview" }).flatMap { nasaURL($0.href) },
                origin: WallpaperOrigin(provider: "NASA", pageURL: page, author: info.center,
                    license: L10n.string(.WallpaperSources.motionSourceNasaUsage)), resolver: entry.href)
        }
        return (items, response.collection.links?.contains(where: { $0.rel == "next" }) == true)
    }

    static func decodeNASAAssets(_ data: Data) throws -> [URL] {
        let order = ["medium", "large", "orig", "small", "mobile", "preview"]
        return try JSONDecoder().decode([URL].self, from: data).compactMap(nasaURL)
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { left, right in
                func rank(_ url: URL) -> Int {
                    order.firstIndex(of: url.deletingPathExtension().lastPathComponent.components(separatedBy: "~").last ?? "") ?? 99
                }
                return rank(left) < rank(right)
            }
    }

    private static func nasaURL(_ url: URL) -> URL? {
        // NASA 的资源清单仍返回 http 字段；仅此官方主机升级为 HTTPS，绝不发送明文请求。
        guard url.host == "images-assets.nasa.gov", url.user == nil, url.password == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    static func feed(_ url: URL) async throws -> (name: String, items: [MotionWallpaper]) {
        let (data, _) = try await WallpaperRemoteAccess.fetch(url, maximumBytes: 4_194_304)
        return try decodeFeed(data, source: url)
    }

    /// 一个明确版本的目录契约。来源可以自行托管，无需 Arc Kit 账号或服务器。
    static func decodeFeed(_ data: Data, source: URL) throws -> (name: String, items: [MotionWallpaper]) {
        let feed = try JSONDecoder().decode(FeedDocument.self, from: data)
        guard feed.version == 1, !feed.name.isEmpty, feed.name.count <= 100, feed.items.count <= 1_000,
              Set(feed.items.map(\.id)).count == feed.items.count else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceInvalidFeedVersionEntries)) }
        let items = try feed.items.map { item -> MotionWallpaper in
            guard !item.id.isEmpty, !item.title.isEmpty, item.title.count <= 300,
                  !item.variants.isEmpty, item.variants.count <= 8,
                  item.variants.allSatisfy({ WallpaperRemoteAccess.valid($0.url) && !$0.title.isEmpty }),
                  item.thumbnail.map(WallpaperRemoteAccess.valid) ?? true, item.preview.map(WallpaperRemoteAccess.valid) ?? true,
                  WallpaperRemoteAccess.valid(item.pageURL) else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceFeedEntryInvalidUrl)) }
            return MotionWallpaper(id: source.absoluteString + "#" + item.id, title: item.title,
                thumbnail: item.thumbnail, preview: item.preview,
                origin: WallpaperOrigin(provider: feed.name, pageURL: item.pageURL, author: item.author, license: item.license), variants: item.variants)
        }
        return (feed.name, items)
    }

    static func fromLink(_ url: URL) async throws -> MotionWallpaper {
        guard WallpaperRemoteAccess.valid(url) else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceEnterHttpsUrlWithoutAccountCredentials)) }
        if isMotionPage(url) {
            let (data, response) = try await WallpaperRemoteAccess.fetch(url, maximumBytes: 4_194_304)
            guard let page = response.url, isMotionPage(page) else { throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceRedirectRejected)) }
            return try decodeMotionDetail(String(decoding: data, as: UTF8.self), page: page)
        }
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw WallpaperError.message(L10n.string(.WallpaperSources.motionSourceSupportsMotionbgsItemPagesDirectMp4))
        }
        return MotionWallpaper(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent,
            preview: url, origin: WallpaperOrigin(provider: url.host ?? L10n.string(.WallpaperSources.motionSourceDirectVideoLink), pageURL: url),
            variants: [.init(title: L10n.string(.WallpaperSources.motionSourceOriginalVideo), url: url)])
    }

    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let match = matches("(?:^|\\s)" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, tag).first else { return nil }
        return match.dropFirst().first(where: { !$0.isEmpty }).map(plain)
    }
    private static func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NASAResponse: Decodable {
    struct Metadata: Decodable { let nasa_id: String; let title: String; let center: String? }
    struct Link: Decodable { let href: URL; let rel: String }
    struct Entry: Decodable { let href: URL; let data: [Metadata]; let links: [Link]? }
    struct Collection: Decodable { let items: [Entry]; let links: [Link]? }
    let collection: Collection
}
private struct FeedDocument: Decodable {
    struct Item: Decodable {
        let id: String; let title: String; let pageURL: URL
        let thumbnail: URL?; let preview: URL?; let author: String?; let license: String?
        let variants: [MotionVariant]
    }
    let version: Int; let name: String; let items: [Item]
}
