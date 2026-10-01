import ArcKitPlatform
import AppKit

/// 系统回读可滞后于写入回执；路径快照也可能指向已被其他壁纸程序删除的文件。
@MainActor
struct WallpaperImageAccess {
    struct Snapshot {
        let url: URL?
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
    }
    let connectedIDs: () -> Set<String>
    let read: (String) -> Snapshot
    let write: (String, URL, [NSWorkspace.DesktopImageOptionKey: Any]) throws -> Void
    let isReadable: (URL) -> Bool
}

/// 仅负责静态图的写入、有限回读和恢复，视频窗口仍由 WallpaperDesktop 管理。
@MainActor
final class WallpaperImageTransaction {
    private let targets: [WallpaperDisplay]
    private let access: WallpaperImageAccess
    private let wait: (Duration) async throws -> Void
    private let snapshots: [String: WallpaperImageAccess.Snapshot]
    private var attempted: [String] = []
    private let delays: [Duration] = [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .milliseconds(1500)]

    init(targets: [WallpaperDisplay], access: WallpaperImageAccess,
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.targets = targets; self.access = access; self.wait = wait
        snapshots = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, access.read($0.id)) })
    }

    /// 返回仍待系统回读确认的屏幕。只有写入异常、取消或断屏才失败，不用旧读值推翻成功回执。
    func apply(_ url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]) async throws -> Set<String> {
        try validateTargets()
        for target in targets {
            try Task.checkCancellation()
            attempted.append(target.id)
            do { try access.write(target.id, url, options) }
            catch { throw WallpaperError.message(L10n.string(.WallpaperPlayback.applyUnavailableSetWallpaper(String(describing: target.name), String(describing: error.localizedDescription)))) }
        }
        return try await confirm(Dictionary(uniqueKeysWithValues: targets.map { ($0.id, url) }), restoring: false)
    }

    func rollback() async throws {
        // 清理使用独立任务：原请求已取消时，仍给系统恢复留出有上限的确认时间。
        try await Task { @MainActor [self] in
            var failures: [String] = []
            var expected: [String: URL] = [:]
            for id in attempted {
                let name = name(id)
                guard access.connectedIDs().contains(id) else { failures.append(L10n.string(.WallpaperPlayback.applyDisplayDisconnected(String(describing: name)))); continue }
                guard let snapshot = snapshots[id], let oldURL = snapshot.url,
                      oldURL.isFileURL, access.isReadable(oldURL) else {
                    failures.append(L10n.string(.WallpaperPlayback.applyOriginalUnavailable(String(describing: name))))
                    continue
                }
                do {
                    try access.write(id, oldURL, snapshot.options)
                    expected[id] = oldURL
                } catch { failures.append(L10n.string(.WallpaperPlayback.applyRestorationRequestFailed(String(describing: name), String(describing: error.localizedDescription)))) }
            }
            let pending = try await confirm(expected, restoring: true)
            for id in pending.sorted() {
                failures.append("\(name(id))（\(access.connectedIDs().contains(id) ? L10n.string(.WallpaperPlayback.applyRestorationRequestedAwaitingSystemConfirmation) : L10n.string(.WallpaperPlayback.applyDisconnectedDuringWrite))）")
            }
            if !failures.isEmpty {
                throw WallpaperError.message(L10n.string(.WallpaperPlayback.applyRestoreUnconfirmed(String(describing: failures.joined(separator: "、")))))
            }
        }.value
    }

    private func confirm(_ expected: [String: URL], restoring: Bool) async throws -> Set<String> {
        func pending() -> Set<String> {
            let connected = access.connectedIDs()
            return Set(expected.compactMap { id, url in
                connected.contains(id) && Self.matches(access.read(id).url, url) ? nil : id
            })
        }
        if !restoring { try Task.checkCancellation(); try validateTargets() }
        var remaining = pending()
        for delay in delays where !remaining.isEmpty {
            try await wait(delay)
            if !restoring { try Task.checkCancellation(); try validateTargets() }
            remaining = pending()
        }
        return remaining
    }

    private func validateTargets() throws {
        let missing = targets.filter { !access.connectedIDs().contains($0.id) }
        guard missing.isEmpty else {
            throw WallpaperError.message(L10n.string(.WallpaperPlayback.applyTargetsDisconnected(String(describing: missing.map(\.name).joined(separator: "、")))))
        }
    }
    private func name(_ id: String) -> String { targets.first { $0.id == id }?.name ?? id }
    static func matches(_ actual: URL?, _ expected: URL) -> Bool {
        actual?.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
    }
}
