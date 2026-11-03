import ArcKitPlatform
import AppKit
import Combine

/// 面板先编辑草稿，一次提交原生位置；不会重启第三方应用、MenuBarAgent 或模拟输入。
@MainActor
final class MenuBarArrangementModel: ObservableObject {
    @Published private(set) var items: [MenuBarArrangementItem] = []
    @Published private(set) var draft = MenuBarArrangementLayout()
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var isStale = false
    @Published private(set) var error: String?
    @Published private(set) var feedback: String?
    @Published private(set) var canUndo = false
    @Published private(set) var permissionRequired = false
    @Published var query = ""
    var prepareToWrite: (() async throws -> Void)?
    private var snapshot: MenuBarArrangementSnapshot?
    private var moves: [MenuBarArrangementMove] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private struct Undo {
        let before: [String: Double], after: [String: Double]
        let collectionBefore: Set<String>, collectionAfter: Set<String>
    }
    private var undo: Undo?
    private let collection: MenuBarCollectionAccess
    private let isPreview: Bool
    private let owner: String
    private let capture: @MainActor () async throws -> MenuBarInventory
    private let readPositions: () throws -> [String: Double]
    private let writePositions: ([String: Double], [String: Double]) throws -> Void

    init(collection: MenuBarCollectionAccess, isPreview: Bool = false,
         owner: String? = nil,
         capture: @escaping @MainActor () async throws -> MenuBarInventory = {
             // 默认异步闭包必须保留 MainActor；await 后继续补入系统设置项时仍在主执行器。
             let inventory = try await MenuBarInspector().captureForInteraction()
             return try MenuBarInputMenu.addingManagedItem(to: inventory)
         },
         readPositions: @escaping () throws -> [String: Double] = { try MenuBarSystemPositions().read() },
         writePositions: @escaping ([String: Double], [String: Double]) throws -> Void = { try MenuBarSystemPositions().write($0, expecting: $1) }) {
        self.collection = collection
        self.isPreview = isPreview
        self.owner = owner ?? (isPreview ? "preview" : (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName))
        self.capture = capture; self.readPositions = readPositions; self.writePositions = writePositions
    }

    var hasChanges: Bool { snapshot.map { $0.layout != draft } ?? false }
    var canEdit: Bool { snapshot != nil && !isLoading && !isApplying && !isStale }
    var canApply: Bool { canEdit && hasChanges }
    var readOnlyItems: [MenuBarArrangementItem] { items.filter { !$0.isEditable && matches($0) } }
    func rows(_ zone: MenuBarArrangementZone) -> [MenuBarArrangementItem] {
        draft[zone].compactMap { id in items.first { $0.id == id } }.filter(matches)
    }
    private func matches(_ item: MenuBarArrangementItem) -> Bool {
        query.isEmpty || [item.observed.displayTitle, item.observed.label ?? "", item.observed.bundleIdentifier ?? ""]
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    func refresh(collectionEnabled: Bool, discard: Bool = false) {
        guard !isApplying, !hasChanges || discard else { return }
        guard !isPreview else { return }
        cancelTask()
        guard #available(macOS 27.0, *) else { error = MenuBarArrangementError.unsupported.localizedDescription; return }
        guard collectionEnabled else {
            snapshot = nil; items = []; draft = .init(); moves = []
            error = MenuBarArrangementError.collectionRequired.localizedDescription; return
        }
        let request = generation
        isLoading = true; error = nil; feedback = nil; permissionRequired = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.isLoading = false; self.task = nil } }
            do {
                let inventory = try await capture()
                try Task.checkCancellation()
                guard generation == request else { return }
                try load(inventory, positions: readPositions())
            } catch is CancellationError { return }
            catch { if generation == request { fail(error) } }
        }
    }

    func load(_ inventory: MenuBarInventory, positions: [String: Double]) throws {
        let current = try MenuBarArrangementSnapshot(inventory: inventory, positions: positions, owner: owner, collectedApplications: try collection.read())
        snapshot = current; items = current.items; draft = current.layout; moves = []
        isStale = false; error = nil; permissionRequired = false
    }

    func setZone(_ id: String, to zone: MenuBarArrangementZone) { move(id, to: zone, reorders: false) }

    func move(_ id: String, to zone: MenuBarArrangementZone, before beforeID: String? = nil, reorders: Bool = true) {
        guard canEdit, id != beforeID, items.contains(where: { $0.id == id && $0.isEditable }), let snapshot else { return }
        let crossing = !draft[zone].contains(id)
        let bundle = items.first { $0.id == id }?.observed.bundleIdentifier
        let siblings = crossing ? (draft.collected + draft.resident).filter { key in
            items.contains { $0.id == key && $0.isEditable && $0.observed.bundleIdentifier == bundle }
        } : [id]
        guard !siblings.contains(beforeID ?? "") else { return }
        let next = moves + siblings.map { MenuBarArrangementMove(itemID: $0, zone: zone, beforeID: beforeID, reorders: reorders) }
        do {
            let planned = try snapshot.applying(next)
            guard planned.layout != draft else { return }
            moves = planned.layout == snapshot.layout ? [] : next
            draft = planned.layout; feedback = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func shift(_ id: String, in zone: MenuBarArrangementZone, by offset: Int) {
        let row = draft[zone]
        guard let index = row.firstIndex(of: id) else { return }
        if offset < 0, index > 0 { move(id, to: zone, before: row[index - 1]) }
        else if offset > 0, index + 1 < row.count { move(id, to: zone, before: index + 2 < row.count ? row[index + 2] : nil) }
    }

    func discard() { guard !isApplying, let snapshot else { return }; draft = snapshot.layout; moves = []; feedback = nil }

    func apply() {
        guard canApply, let baseline = snapshot else { return }
        cancelTask()
        let request = generation
        let operations = moves
        isApplying = true; error = nil; feedback = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == request { isApplying = false; task = nil } }
            do {
                try await prepareToWrite?()
                try Task.checkCancellation()
                guard generation == request else { return }
                let inventory = try await (isPreview ? baseline.inventory : capture())
                try Task.checkCancellation()
                guard generation == request else { return }
                let current = try MenuBarArrangementSnapshot(inventory: inventory,
                    positions: isPreview ? baseline.positions : readPositions(), owner: owner, collectedApplications: try collection.read())
                // 徽标宽度变化可以改变数值；原有归属、顺序与进程身份没变就继续采用最新数值。
                guard current.collectedApplications == baseline.collectedApplications, current.layout == baseline.layout, current.hasSameTargets(as: baseline) else { throw MenuBarArrangementError.changed }
                let plan = try current.applying(operations)
                let before = current.positions.filter { plan.patch[$0.key] != nil }
                try await commit(positions: plan.patch, expected: current.expectation,
                    selection: plan.collectedApplications, expecting: current.collectedApplications)
                undo = Undo(before: before, after: plan.patch, collectionBefore: current.collectedApplications, collectionAfter: plan.collectedApplications)
                canUndo = !before.isEmpty || current.collectedApplications != plan.collectedApplications
                if !isPreview { try await Task.sleep(for: .milliseconds(500)) }
                try Task.checkCancellation()
                guard generation == request else { return }
                let after = isPreview ? current.positions.merging(plan.patch) { _, new in new } : try readPositions()
                let confirmed = try MenuBarArrangementSnapshot(inventory: inventory, positions: after, owner: owner, collectedApplications: try collection.read())
                guard confirmed.collectedApplications == plan.collectedApplications, confirmed.layout == plan.layout else { throw MenuBarArrangementError.unconfirmed }
                undo = Undo(before: before, after: after.filter { before[$0.key] != nil }, collectionBefore: current.collectedApplications, collectionAfter: plan.collectedApplications)
                try load(inventory, positions: after)
                feedback = L10n.string(.MenuBar.arrangeApplied)
            } catch is CancellationError { return }
            catch { if generation == request { fail(error) } }
        }
    }

    func undoLastApply() {
        guard !isApplying, !hasChanges, let undo, let snapshot else { return }
        cancelTask(); let request = generation
        isApplying = true; error = nil; feedback = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == request { isApplying = false; task = nil } }
            do {
                try await prepareToWrite?()
                try Task.checkCancellation()
                guard generation == request else { return }
                let inventory = try await (isPreview ? snapshot.inventory : capture())
                try Task.checkCancellation()
                guard generation == request else { return }
                let current = isPreview ? snapshot.positions : try readPositions()
                let observed = try MenuBarArrangementSnapshot(inventory: inventory, positions: current, owner: owner, collectedApplications: try collection.read())
                for key in undo.before.keys {
                    guard let original = snapshot.items.first(where: { $0.id == key }),
                          let live = observed.items.first(where: { $0.id == key && $0.isEditable }),
                          MenuBarArrangementSnapshot.sameOwner(live.observed, original.observed) else { throw MenuBarArrangementError.changed }
                }
                guard observed.collectedApplications == undo.collectionAfter, undo.after.allSatisfy({ current[$0.key] == $0.value }) else { throw MenuBarArrangementError.changed }
                try await commit(positions: undo.before, expected: undo.after, selection: undo.collectionBefore, expecting: undo.collectionAfter)
                if !isPreview { try await Task.sleep(for: .milliseconds(500)) }
                try Task.checkCancellation()
                guard generation == request else { return }
                try load(inventory, positions: isPreview ? current.merging(undo.before) { _, new in new } : readPositions())
                self.undo = nil; canUndo = false; feedback = L10n.string(.MenuBar.arrangeUndone)
            } catch is CancellationError { return }
            catch { if generation == request { fail(error) } }
        }
    }

    private func commit(positions: [String: Double], expected: [String: Double], selection: Set<String>, expecting previous: Set<String>) async throws {
        let changed = selection != previous
        if changed { try await collection.write(selection, previous) }
        do {
            try Task.checkCancellation()
            if !isPreview, !positions.isEmpty { try writePositions(positions, expected) }
        } catch {
            // 两种存储不能共用事务：系统排序失败时只补偿本次名单提交，不覆盖其他人的后续选择。
            if changed {
                do { try await collection.write(previous, selection) }
                catch { throw MenuBarArrangementError.unconfirmed }
            }
            throw error
        }
    }

    func invalidate() {
        let interrupted = isApplying
        cancelTask()
        guard snapshot != nil else { return }
        isStale = true
        error = interrupted && undo != nil ? L10n.string(.MenuBar.arrangeUnconfirmed) : L10n.string(.MenuBar.arrangeChanged)
    }
    func leave() { if isLoading || isApplying { invalidate() } }
    func finish() async { await task?.value }
    private func fail(_ error: Error) {
        self.error = error.localizedDescription; isStale = true
        permissionRequired = (error as? MenuBarItemAccessError)?.requiresPermission == true
    }
    private func cancelTask() {
        generation = UUID(); task?.cancel(); task = nil; isLoading = false; isApplying = false
    }
}
