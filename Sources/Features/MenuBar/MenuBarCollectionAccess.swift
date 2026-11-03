import ArcKitPlatform
import Foundation

/// 收纳归属只经同一 SettingsEditor 提交；系统位置表仅负责顺序。
@MainActor
struct MenuBarCollectionAccess {
    let read: @MainActor () throws -> Set<String>
    let write: @MainActor (Set<String>, Set<String>) async throws -> Void

    init(editor: SettingsEditor<MenuBarSettings>) {
        read = {
            guard let settings = editor.committedSettings else { throw MenuBarArrangementError.unavailable }
            return settings.collectedApplications
        }
        write = { value, expected in
            guard !editor.hasUncommittedChanges, editor.committedSettings?.collectedApplications == expected else {
                throw MenuBarArrangementError.changed
            }
            editor.update(actionName: L10n.string(.MenuBar.arrangeApply)) { $0.collectedApplications = value }
            guard await editor.commitPendingChanges() else {
                throw MenuBarArrangementError.saveFailed(editor.failureMessage ?? L10n.string(.MenuBar.flowSaveFailed))
            }
        }
    }
    init(read: @escaping @MainActor () throws -> Set<String>, write: @escaping @MainActor (Set<String>, Set<String>) async throws -> Void) {
        self.read = read; self.write = write
    }
    static func preview(_ initial: Set<String> = []) -> Self {
        var value = initial
        return .init(read: { value }, write: { next, expected in
            guard value == expected else { throw MenuBarArrangementError.changed }; value = next
        })
    }
    static var unavailable: Self {
        .init(read: { throw MenuBarArrangementError.unavailable }, write: { _, _ in throw MenuBarArrangementError.unavailable })
    }
}

/// 只在旧数据库新增名单列时读取一次；运行时不再依赖这些旧锚点。
enum MenuBarLegacyCollection {
    static func read() -> Set<String> {
        do {
            let positions = try MenuBarSystemPositions().read()
            let rows = try MenuBarVisibilityStore().read()
            let candidates = imported(from: positions, owner: "com.archalo.arckit")
            return Set(candidates.filter { $0 == MenuBarInputMenu.bundleIdentifier || (try? MenuBarVisibilityStore.index(of: $0, in: rows)) != nil })
        } catch {
            ArcKitLog.append("menu-bar legacy selection unavailable; choose collection in management: \(error.localizedDescription)")
            return []
        }
    }
    static func imported(from positions: [String: Double], owner: String) -> Set<String> {
        let prefix = "status:\(owner)::menu-bar.group-v3."
        guard let control = positions[prefix + "toggle"], let boundary = positions[prefix + "hidden"],
              control.isFinite, boundary.isFinite, boundary > control else { return [] }
        var groups: [String: [Double]] = [:]
        for (key, value) in positions where key.hasPrefix("status:") && value.isFinite {
            let parts = key.dropFirst(7).components(separatedBy: "::")
            if parts.count == 2, parts[0] != owner, !MenuBarVisibilitySession.systemOwners.contains(parts[0]) {
                groups[parts[0], default: []].append(value)
            }
        }
        let result = Set(groups.filter { $0.value.allSatisfy { $0 > boundary } }.keys)
        return result
    }
}
