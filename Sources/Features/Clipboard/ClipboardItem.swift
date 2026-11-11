import Foundation
import ImageIO

enum ClipboardContentKind: String, Codable, CaseIterable, Sendable { case text, link, image }

struct ClipboardContent: Codable, Equatable, Sendable {
    static let maximumTextBytes = 256 * 1024
    static let maximumImageBytes = 10 * 1024 * 1024
    var kind: ClipboardContentKind
    var text: String?
    var rtf: Data?
    var png: Data?

    func validate() throws {
        switch kind {
        case .text, .link:
            guard let text, !text.isEmpty, text.utf8.count <= Self.maximumTextBytes,
                  (rtf?.count ?? 0) <= Self.maximumTextBytes, png == nil else { throw ClipboardError.invalidContent }
        case .image:
            guard let png, !png.isEmpty, png.count <= Self.maximumImageBytes,
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), Self.hasSafeImageDimensions(png), text == nil, rtf == nil
            else { throw ClipboardError.invalidContent }
        }
    }

    static func hasSafeImageDimensions(_ data: Data) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.doubleValue > 0 && height.doubleValue > 0 && width.doubleValue * height.doubleValue <= 40_000_000
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var content: ClipboardContent?
    var createdAt = Date()
    var modifiedAt = Date()
    var mutationID: String = UUID().uuidString
    var sourceBundleID: String
    var sourceName: String
    var deviceName: String
    var favorite = false
    var deleted = false

    mutating func touch() { modifiedAt = Date(); mutationID = UUID().uuidString }
    mutating func erase() { deleted = true; content = nil; sourceBundleID = ""; sourceName = ""; deviceName = ""; favorite = false; touch() }

    func validate() throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: mutationID) != nil,
              createdAt.timeIntervalSince1970.isFinite, modifiedAt.timeIntervalSince1970.isFinite,
              sourceBundleID.count <= 255, sourceName.count <= 255, deviceName.count <= 255,
              deleted ? content == nil : content != nil else { throw ClipboardError.invalidCloudRecord }
        try content?.validate()
    }

    /// 删除优先；其余操作按时间与随机修订号形成确定顺序，不依赖设备到达顺序。
    func supersedes(_ other: Self) -> Bool {
        if deleted != other.deleted { return deleted }
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        return mutationID > other.mutationID
    }
}

struct ClipboardSummary: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ClipboardContentKind
    let preview: String
    let sourceName: String
    let sourceBundleID: String
    let deviceName: String
    let createdAt: Date
    let favorite: Bool
    let pending: Bool
}

struct ClipboardSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ClipboardUpload: Sendable {
    let item: ClipboardItem
    let systemFields: Data?
}

struct ClipboardRemoteChange: Sendable {
    let item: ClipboardItem
    let systemFields: Data
}
