import ArcKitPlatform
@preconcurrency import CloudKit
import Foundation
import Security

struct ClipboardCloudPage: Sendable {
    let changes: [ClipboardRemoteChange]
    let removed: [String]
    let token: Data
    let more: Bool
}

struct ClipboardCloudSaveResult: Sendable {
    let changes: [ClipboardRemoteChange]
    let failure: (any Error)?
}

protocol ClipboardCloudTransport: Sendable {
    func account() async throws -> String
    func prepare() async throws
    func fetch(token: Data?) async throws -> ClipboardCloudPage
    func save(_ uploads: [ClipboardUpload]) async throws -> ClipboardCloudSaveResult
}

enum ClipboardCloudConfiguration {
    /// 未签名或 ad-hoc 版本不能初始化 CKContainer：SDK 可能抛出不可捕获的权限异常。
    static func containerIdentifier() -> String? {
        guard let requested = Bundle.main.object(forInfoDictionaryKey: "ArcKitClipboardCloudContainer") as? String,
              requested.hasPrefix("iCloud."), !requested.contains("$(") else { return nil }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let services = entitlements["com.apple.developer.icloud-services"] as? [String], services.contains("CloudKit"),
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String], containers.contains(requested)
        else { return nil }
        return requested
    }
}

/// 私有分区保存独立记录与持久删除标记；没有业务服务器，也不写系统剪贴板。
actor NativeClipboardCloud: ClipboardCloudTransport {
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "ArcKitClipboard", ownerName: CKCurrentUserDefaultName)
    private let paths: ArcKitStoragePaths
    private var database: CKDatabase { container.privateCloudDatabase }

    init(identifier: String, paths: ArcKitStoragePaths) {
        container = CKContainer(identifier: identifier)
        self.paths = paths
    }

    func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw ClipboardError.signedOut }
        return try await container.userRecordID().recordName
    }

    func prepare() async throws { _ = try await database.save(CKRecordZone(zoneID: zoneID)) }

    func fetch(token: Data?) async throws -> ClipboardCloudPage {
        let previous = try token.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: previous ?? nil, resultsLimit: 10)
            let changes = try page.modificationResultsByID.values.map { try Self.decode($0.get().record) }
            return ClipboardCloudPage(changes: changes,
                removed: page.deletions.map { $0.recordID.recordName },
                token: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true), more: page.moreComing)
        } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
            // 令牌过期只重拉记录；本地隐藏与远端删除标记仍参加合并。
            return try await fetch(token: nil)
        }
    }

    func save(_ uploads: [ClipboardUpload]) async throws -> ClipboardCloudSaveResult {
        let folder = try paths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = try uploads.map { upload -> CKRecord in
            try upload.item.validate()
            let record: CKRecord
            if let fields = upload.systemFields {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
                decoder.requiresSecureCoding = true
                guard let restored = CKRecord(coder: decoder), restored.recordID.recordName == upload.item.id,
                      restored.recordID.zoneID == zoneID else { throw ClipboardError.invalidCloudRecord }
                record = restored
                decoder.finishDecoding()
            } else { record = CKRecord(recordType: "ArcKitClipboardItem", recordID: .init(recordName: upload.item.id, zoneID: zoneID)) }
            var metadata = upload.item
            let png = metadata.content?.png
            metadata.content?.png = nil
            record.encryptedValues["payload"] = try JSONEncoder().encode(metadata) as NSData
            // CKAsset 由 CloudKit 加密；系统字段只保存修订信息，不放剪贴板正文。
            if let png {
                let path = folder.appendingPathComponent(upload.item.id + ".png")
                try png.write(to: path, options: .atomic)
                try ArcKitStoragePaths.secureFile(path)
                record["image"] = CKAsset(fileURL: path)
            } else { record["image"] = nil }
            return record
        }
        let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        var changes: [ClipboardRemoteChange] = []
        var failure: Error?
        for result in result.saveResults.values {
            do { changes.append(try Self.decode(result.get())) }
            catch let error as CKError where error.code == .serverRecordChanged {
                do {
                    guard let server = error.serverRecord else { throw error }
                    // 冲突回包不保证带可读的 CKAsset 文件，重新获取完整服务端记录。
                    changes.append(try Self.decode(try await database.record(for: server.recordID)))
                } catch { failure = error }
            } catch { failure = error }
        }
        // 部分失败不丢成功回执；未确认的记录仍 dirty，下轮按服务器修订合并后重试。
        return ClipboardCloudSaveResult(changes: changes, failure: failure)
    }

    static func decode(_ record: CKRecord) throws -> ClipboardRemoteChange {
        guard record.recordType == "ArcKitClipboardItem", let data = record.encryptedValues["payload"] as? Data,
              data.count <= ClipboardContent.maximumTextBytes * 3 else { throw ClipboardError.invalidCloudRecord }
        var item = try JSONDecoder().decode(ClipboardItem.self, from: data)
        guard item.id == record.recordID.recordName else { throw ClipboardError.invalidCloudRecord }
        if item.content?.kind == .image {
            guard let asset = record["image"] as? CKAsset, let file = asset.fileURL,
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= ClipboardContent.maximumImageBytes else { throw ClipboardError.invalidCloudRecord }
            item.content?.png = try Data(contentsOf: file)
        }
        try item.validate()
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder); encoder.finishEncoding()
        return ClipboardRemoteChange(item: item, systemFields: encoder.encodedData)
    }
}
