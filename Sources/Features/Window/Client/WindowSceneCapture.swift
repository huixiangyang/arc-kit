import ArcKitPlatform
import ArcKitWindow
import Foundation

/// 将用户明确选择的实时窗口合入场景；无法确认的旧条目必须保留，不能因缺屏而丢失。
enum WindowSceneCapture {
    static func matchingEntry(for candidate: WindowSceneCandidate, scene: WindowScene, inventory: WindowSceneInventory) -> WindowSceneEntry? {
        let explicitMatches = scene.entries.filter { entry in
            guard let hint = entry.sessionHint, hint.hostLaunchID == inventory.hostLaunchID else { return false }
            return candidate.sessionHint == hint && candidate.id == hint.capturedWindowID
        }
        if explicitMatches.count == 1 { return explicitMatches.first }
        guard explicitMatches.isEmpty, let plan = try? WindowSceneMatcher.plan(scene: scene, inventory: inventory) else { return nil }
        let matches = plan.filter { $0.status == .ready && $0.candidateID == candidate.id }
        guard matches.count == 1, let id = matches.first?.entryID else { return nil }
        return scene.entries.first(where: { $0.id == id })
    }

    static func preservedEntries(scene: WindowScene, inventory: WindowSceneInventory) -> [WindowSceneEntry] {
        let matchedIDs = Set(inventory.candidates.compactMap { matchingEntry(for: $0, scene: scene, inventory: inventory)?.id })
        return scene.entries.filter { !matchedIDs.contains($0.id) }
    }

    static func update(scene: WindowScene, inventory: WindowSceneInventory, selectedIDs: Set<UUID>) throws -> WindowScene {
        guard selectedIDs.isSubset(of: Set(inventory.candidates.map(\.id))) else {
            throw WindowSceneClientError(message: L10n.string(.WindowSettings.scenesSelectionExpired))
        }
        let preserved = preservedEntries(scene: scene, inventory: inventory)
        let capturedEntries = try inventory.candidates.filter { selectedIDs.contains($0.id) }.map { candidate in
            guard let display = inventory.displays.first(where: { $0.id == candidate.displayID }) else {
                throw WindowSceneValidationError.invalidDisplay
            }
            var captured = try WindowSceneEntry.capture(candidate: candidate, display: display)
            if let existing = matchingEntry(for: candidate, scene: scene, inventory: inventory) {
                captured.id = existing.id
                captured.titleMatchMode = existing.titleMatchMode
                captured.titleMatchValue = existing.titleMatchValue
            }
            return captured
        }
        let entries = capturedEntries + preserved
        guard !entries.isEmpty else { throw WindowSceneValidationError.emptyScene }
        guard entries.count <= WindowScene.maximumEntryCount else { throw WindowSceneValidationError.tooManyEntries }
        let preservedDisplayIDs = Set(preserved.map(\.displayID))
        let capturedDisplayIDs = Set(capturedEntries.map(\.displayID))
        var displays = inventory.displays.filter { capturedDisplayIDs.contains($0.id) }
        displays.append(contentsOf: scene.displays.filter { old in
            preservedDisplayIDs.contains(old.id) && !displays.contains(where: { $0.id == old.id })
        })
        var updated = scene
        updated.entries = entries
        updated.displays = displays
        if let focus = updated.focusEntryID, !entries.contains(where: { $0.id == focus }) { updated.focusEntryID = nil }
        return updated
    }
}
