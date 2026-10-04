import ArcKitPlatform
import ArcKitWindow
import AppKit
import Foundation

/// 场景执行器只持有 Host 内的 AX 引用。整个批次先固定计划，再逐项写入与回读。
@MainActor
final class WindowSceneRuntime {
    private struct UndoEntry {
        var entryID: UUID
        var target: WindowActionTarget
        var frame: CGRect
        var displayID: String?
        var displayVisibleFrame: CGRect?
        var applicationLaunchDate: Date?
    }
    private struct UndoBatch {
        var sceneID: UUID
        var sceneName: String
        var entries: [UndoEntry]
    }

    let hostLaunchID: UUID
    private let client: WindowAccessibilityClient
    private let verifier: WindowResultVerifier
    private let displaysProvider: @MainActor () -> [WindowSceneDisplay]
    private var retainedWindows: [UUID: WindowSceneAXWindow] = [:]
    private var pinnedWindowIDs: Set<UUID> = []
    private var currentWindowIDs: Set<UUID> = []
    private var undoBatches: [UUID: UndoBatch] = [:]
    private var undoOrder: [UUID] = []

    init(client: WindowAccessibilityClient, displaysProvider: @escaping @MainActor () -> [WindowSceneDisplay], hostLaunchID: UUID = UUID()) {
        self.hostLaunchID = hostLaunchID
        self.client = client
        self.displaysProvider = displaysProvider
        verifier = WindowResultVerifier(accessibilityClient: client, fullScreenVerificationStableInterval: 0)
    }

    func updateScenes(_ scenes: [WindowScene]) {
        // 已提交场景的同 Host 令牌保持有界存活，窗口暂时最小化/离开 Space 不丢身份。
        pinnedWindowIDs = Set(scenes.flatMap(\.entries).compactMap { entry in
            guard let hint = entry.sessionHint, hint.hostLaunchID == hostLaunchID else { return nil }
            return hint.capturedWindowID
        })
        retainedWindows = retainedWindows.filter { pinnedWindowIDs.contains($0.key) || currentWindowIDs.contains($0.key) }
    }

    func inventory(isValid: @MainActor () -> Bool) async throws -> WindowSceneInventory {
        let windows = try await client.sceneWindows(isValid: isValid)
        guard isValid() else { throw CancellationError() }
        let displays = displaysProvider()
        var candidates: [WindowSceneCandidate] = []
        for window in windows {
            guard isValid() else { throw CancellationError() }
            let target = window.target
            guard let bundle = target.bundleIdentifier,
                  ![ArcKitConstants.appBundleIdentifier, ArcKitConstants.runtimeHostBundleIdentifier,
                    ArcKitConstants.finderExtensionBundleIdentifier].contains(bundle),
                  target.pid != ProcessInfo.processInfo.processIdentifier,
                  let frame = try? await client.frame(of: target),
                  let display = displays.max(by: { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area }),
                  display.visibleFrame.intersection(frame).area > 0 else { continue }
            guard isValid() else { throw CancellationError() }
            let id = retainedID(for: window) ?? UUID()
            retainedWindows[id] = window
            candidates.append(.init(id: id, bundleIdentifier: bundle, applicationName: window.applicationName,
                                    title: target.restoreKey.title == "-" ? "" : target.restoreKey.title,
                                    displayID: display.id, frame: frame,
                                    sessionHint: .init(hostLaunchID: hostLaunchID, capturedWindowID: id,
                                                       processIdentifier: target.pid,
                                                       applicationLaunchDate: window.applicationLaunchDate,
                                                       windowNumber: target.restoreKey.windowNumber)))
        }
        // 只保留本轮候选与已提交场景的引用；后者受场景/条目数量上限约束。
        // 匹配计划仅使用本轮 inventory，不会因为保留旧 AX 引用而操作其他 Space。
        currentWindowIDs = Set(candidates.map(\.id))
        retainedWindows = retainedWindows.filter { currentWindowIDs.contains($0.key) || pinnedWindowIDs.contains($0.key) }
        return .init(hostLaunchID: hostLaunchID, displays: displays, candidates: candidates)
    }

    func apply(_ scene: WindowScene, settings: WindowManagementSettings, isValid: @MainActor () -> Bool) async -> WindowSceneExecutionReport {
        var items: [WindowSceneItemResult] = []
        var moved: [UndoEntry] = []
        var focusTarget: WindowActionTarget?
        var focusFailure: String?
        do {
            let inventory = try await inventory(isValid: isValid)
            let plan = try WindowSceneMatcher.plan(scene: scene, inventory: inventory)
            // 之后不再询问前台窗口；切换焦点不会改变已固定的目标。
            let targets = retainedWindows
            for entry in plan {
                guard isValid() else {
                    items.append(.init(entryID: entry.entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneCancelled)))
                    continue
                }
                guard entry.status == .ready, let candidateID = entry.candidateID,
                      let target = targets[candidateID]?.target, let targetFrame = entry.targetFrame else {
                    items.append(.init(entryID: entry.entryID, status: itemStatus(entry.status), candidateIDs: entry.candidateIDs))
                    continue
                }
                guard !settings.isExcluded(bundleIdentifier: target.bundleIdentifier) else {
                    items.append(.init(entryID: entry.entryID, status: .excludedApplication))
                    continue
                }
                guard displaysMatch(inventory.displays) else {
                    items.append(.init(entryID: entry.entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneDisplayChanged)))
                    continue
                }
                guard let definition = scene.entries.first(where: { $0.id == entry.entryID }),
                      displaysProvider().contains(where: { $0.id == definition.displayID }) else {
                    items.append(.init(entryID: entry.entryID, status: .missingDisplay))
                    continue
                }
                guard let targetDisplay = inventory.displays.first(where: { $0.id == definition.displayID }) else {
                    items.append(.init(entryID: entry.entryID, status: .missingDisplay))
                    continue
                }
                let outcome = await move(target, entryID: entry.entryID, to: targetFrame, display: targetDisplay) {
                    isValid() && self.displaysMatch(inventory.displays)
                }
                items.append(outcome.result)
                if let original = outcome.originalFrame {
                    let originalDisplay = inventory.displays.max {
                        $0.visibleFrame.intersection(original).area < $1.visibleFrame.intersection(original).area
                    }
                    moved.append(.init(entryID: entry.entryID, target: target, frame: original,
                                       displayID: originalDisplay.flatMap { $0.visibleFrame.intersection(original).area > 0 ? $0.id : nil },
                                       displayVisibleFrame: originalDisplay?.visibleFrame,
                                       applicationLaunchDate: targets[candidateID]?.applicationLaunchDate))
                }
                if scene.focusEntryID == entry.entryID, outcome.result.status.isSuccess || outcome.result.status == .constrained {
                    focusTarget = target
                }
            }
            if scene.focusEntryID != nil {
                if let focusTarget, isValid() {
                    do { try await client.focusWindow(focusTarget, isValid: isValid) }
                    catch { focusFailure = error.localizedDescription }
                } else { focusFailure = L10n.string(.WindowRuntime.sceneFocusUnavailable) }
            }
        } catch {
            items = scene.entries.map { .init(entryID: $0.id, status: .unavailable, message: error.localizedDescription) }
        }
        // 配置更改或超时也要保留此前已实际移动窗口的撤销信息，不能丢掉半完成批次。
        let token = retainUndo(sceneID: scene.id, sceneName: scene.name, entries: moved)
        return .init(sceneID: scene.id, sceneName: scene.name, items: items, undoToken: token, focusFailureMessage: focusFailure)
    }

    func undo(_ token: UUID, settings: WindowManagementSettings, isValid: @MainActor () -> Bool) async throws -> WindowSceneExecutionReport {
        guard let batch = undoBatches[token] else { throw WindowSceneRuntimeError.undoExpired }
        let inventory = try await inventory(isValid: isValid)
        let currentWindows = inventory.candidates.compactMap { retainedWindows[$0.id] }
        var results: [WindowSceneItemResult] = []
        var pending: [UndoEntry] = []
        for entry in batch.entries {
            guard isValid() else {
                results.append(.init(entryID: entry.entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneCancelled)))
                pending.append(entry)
                continue
            }
            guard !settings.isExcluded(bundleIdentifier: entry.target.bundleIdentifier) else {
                results.append(.init(entryID: entry.entryID, status: .excludedApplication))
                pending.append(entry)
                continue
            }
            guard currentWindows.contains(where: {
                $0.target.pid == entry.target.pid && $0.target.bundleIdentifier == entry.target.bundleIdentifier
                    && $0.applicationLaunchDate == entry.applicationLaunchDate && CFEqual($0.target.element, entry.target.element)
            }) else {
                results.append(.init(entryID: entry.entryID, status: .missingWindow))
                pending.append(entry)
                continue
            }
            guard let originalDisplayID = entry.displayID,
                  let originalDisplayFrame = entry.displayVisibleFrame,
                  let currentDisplay = displaysProvider().first(where: { $0.id == originalDisplayID }) else {
                results.append(.init(entryID: entry.entryID, status: .missingDisplay))
                pending.append(entry)
                continue
            }
            guard verifier.framesMatch(currentDisplay.visibleFrame, originalDisplayFrame) else {
                results.append(.init(entryID: entry.entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneDisplayChanged)))
                pending.append(entry)
                continue
            }
            let outcome = await move(entry.target, entryID: entry.entryID, to: entry.frame, display: currentDisplay, isValid: isValid)
            results.append(outcome.result)
            if !outcome.result.status.isSuccess { pending.append(entry) }
        }
        if pending.isEmpty {
            undoBatches[token] = nil
            undoOrder.removeAll { $0 == token }
        } else { undoBatches[token]?.entries = pending }
        return .init(sceneID: batch.sceneID, sceneName: batch.sceneName, operation: .undo,
                     items: results, undoToken: pending.isEmpty ? nil : token)
    }

    private func move(_ target: WindowActionTarget, entryID: UUID, to expected: CGRect, display: WindowSceneDisplay,
                      isValid: @MainActor () -> Bool) async -> (result: WindowSceneItemResult, originalFrame: CGRect?) {
        var original: CGRect?
        var didAttemptWrite = false
        do {
            guard !client.isApplicationTerminated(pid: target.pid) else { throw WindowManagementExecutionError.captureApplicationUnavailable }
            try await client.validateWindowAdjustable(target)
            try await client.validateSceneWindowVisible(target, isValid: isValid)
            guard isValid() else { throw CancellationError() }
            let before = try await client.frame(of: target)
            original = before
            guard isValid() else { throw CancellationError() }
            guard let currentDisplay = displaysProvider().first(where: { $0.id == display.id }) else {
                return (.init(entryID: entryID, status: .missingDisplay), nil)
            }
            guard verifier.framesMatch(currentDisplay.visibleFrame, display.visibleFrame) else {
                return (.init(entryID: entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneDisplayChanged)), nil)
            }
            if verifier.framesMatch(before, expected) { return (.init(entryID: entryID, status: .unchanged, actualFrame: before), nil) }
            didAttemptWrite = true
            try await client.setFrame(expected, for: target)
            guard isValid() else {
                return (.init(entryID: entryID, status: .unavailable, message: L10n.string(.WindowRuntime.sceneCancelled)), before)
            }
            let actual = try await verifier.verifiedFrame(for: target, expected: expected, shouldContinue: isValid)
            let moved = !verifier.framesMatch(actual, before)
            if verifier.framesMatch(actual, expected) {
                return (.init(entryID: entryID, status: .applied, actualFrame: actual), moved ? before : nil)
            }
            // 未精确命中只报告约束，不将单窗口的宽松近似成功扩散成整个场景成功。
            return (.init(entryID: entryID, status: moved ? .constrained : .failed,
                          message: L10n.string(.WindowRuntime.sceneFrameMismatch), actualFrame: actual), moved ? before : nil)
        } catch {
            // AX 可能先移动位置再拒绝尺寸；读取真实结果后仍需提供撤销。
            let actual = didAttemptWrite && isValid() ? try? await client.frame(of: target) : nil
            let moved = original.flatMap { before in actual.map { !verifier.framesMatch($0, before) } } ?? false
            // 已发出写入但回读失败时仍保留恢复点；这不算成功，撤销时会重新核验原窗口。
            // 否则 AX 部分写入后权限被撤销，会永久丢失用户原来的布局。
            let recoveryFrame = moved || (didAttemptWrite && actual == nil) ? original : nil
            return (.init(entryID: entryID, status: .failed, message: error.localizedDescription, actualFrame: actual), recoveryFrame)
        }
    }

    private func retainedID(for window: WindowSceneAXWindow) -> UUID? {
        for (id, old) in retainedWindows {
            guard old.target.pid == window.target.pid,
                  old.target.bundleIdentifier == window.target.bundleIdentifier,
                  old.applicationLaunchDate == window.applicationLaunchDate else { continue }
            if CFEqual(old.target.element, window.target.element) { return id }
        }
        return nil
    }

    private func displaysMatch(_ expected: [WindowSceneDisplay]) -> Bool {
        let current = displaysProvider()
        guard current.count == expected.count else { return false }
        return expected.allSatisfy { before in
            current.contains { $0.id == before.id && verifier.framesMatch($0.visibleFrame, before.visibleFrame) }
        }
    }

    private func retainUndo(sceneID: UUID, sceneName: String, entries: [UndoEntry]) -> UUID? {
        guard !entries.isEmpty else { return nil }
        let token = UUID()
        undoBatches[token] = .init(sceneID: sceneID, sceneName: sceneName, entries: entries)
        undoOrder.append(token)
        while undoOrder.count > 16 { undoBatches[undoOrder.removeFirst()] = nil }
        return token
    }

    private func itemStatus(_ status: WindowScenePlanStatus) -> WindowSceneItemStatus {
        switch status {
        case .ready: .unavailable
        case .missingWindow: .missingWindow
        case .ambiguousWindow: .ambiguousWindow
        case .missingDisplay: .missingDisplay
        case .conflictingAssignment: .conflictingAssignment
        }
    }

    static func displays() -> [WindowSceneDisplay] {
        let screens = NSScreen.screens
        let coordinates = ArcKitScreenCoordinateSpace(screenFrames: screens.map(\.frame))
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let value = CFUUIDCreateString(nil, uuid) else { return nil }
            return .init(id: value as String, name: screen.localizedName,
                         visibleFrame: coordinates.appKitToAccessibility(screen.visibleFrame))
        }
    }
}

enum WindowSceneRuntimeError: LocalizedError {
    case undoExpired, unavailable, missingScene, busy
    var errorDescription: String? {
        switch self {
        case .undoExpired: L10n.string(.WindowRuntime.sceneUndoExpired)
        case .unavailable: L10n.string(.WindowRuntime.sceneUnavailable)
        case .missingScene: L10n.string(.WindowRuntime.sceneMissing)
        case .busy: L10n.string(.WindowRuntime.actionWindowActionRunningRetry)
        }
    }
}
