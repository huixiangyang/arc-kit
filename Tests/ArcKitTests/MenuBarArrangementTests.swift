import Foundation
import Testing
@testable import ArcKitApplication

@Suite("菜单栏面板编排")
struct MenuBarArrangementTests {
    private let owner = "test.owner"
    private let a = "status:app.a::Item-0"
    private let b = "status:app.b::Item-0"
    private let c = "status:app.c::Item-0"
    private var positions: [String: Double] {
        ["status:test.owner::menu-bar.group-v3.toggle": 400, "status:test.owner::menu-bar.group-v3.hidden": 434,
         "status:app.a::Item-0": 300, "status:app.b::Item-0": 200, "status:app.c::Item-0": 600, "module:Clock": 0]
    }
    private func item(_ bundle: String, id: String? = nil, pid: Int32 = 9000) -> MenuBarObservedItem {
        .init(id: UUID(), processID: pid, processLaunchDate: Date(timeIntervalSince1970: 100), bundleIdentifier: bundle,
              applicationName: bundle, accessibilityIdentifier: id, frame: nil, displayID: nil,
              declaresPress: true, declaresShowMenu: false, positionSettable: false)
    }
    private func inventory(_ items: [MenuBarObservedItem]? = nil) -> MenuBarInventory {
        .init(id: UUID(), capturedAt: Date(), systemVersion: "fixture", accessibility: .granted,
              displays: [.init(id: 1, name: "fixture", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                               topBand: CGRect(x: 0, y: 0, width: 1920, height: 32), notch: nil, scale: 1)],
              items: items ?? [item("app.a"), item("app.b"), item("app.c"), item("com.apple.MenuBarAgent", id: "clock")], issues: [])
    }

    @Test("只接受唯一身份；多图标精确键可编排，匿名冲突和系统项只读")
    func identityResolution() throws {
        var values = positions
        values["status:app.multi::primary"] = 100
        values["status:app.multi::secondary"] = 150
        let known = try MenuBarArrangementSnapshot(inventory: inventory([item("app.multi", id: "primary"), item("app.multi", id: "secondary")]), positions: values, owner: owner, collectedApplications: ["app.c"])
        #expect(known.items.allSatisfy { $0.isEditable })
        let ambiguous = try MenuBarArrangementSnapshot(inventory: inventory([item("app.multi"), item("app.multi"), item("com.apple.MenuBarAgent")]), positions: values, owner: owner, collectedApplications: ["app.c"])
        #expect(ambiguous.items.allSatisfy { !$0.isEditable })
        let single = try MenuBarArrangementSnapshot(inventory: inventory(), positions: positions, owner: owner, collectedApplications: ["app.c"])
        #expect(single.layout.resident == [a, b] && single.layout.collected == [c])
        values[b] = 300
        let tied = try MenuBarArrangementSnapshot(inventory: inventory(), positions: values, owner: owner, collectedApplications: ["app.c"])
        #expect(tied.layout.resident.isEmpty)
    }

    @Test("跨区和区内排序只写移动项，失效参照和外部变更不能静默覆盖")
    func planningAndConflict() throws {
        let source = try MenuBarArrangementSnapshot(inventory: inventory(), positions: positions, owner: owner, collectedApplications: ["app.c"])
        let plan = try source.applying([.init(itemID: b, zone: .collected, beforeID: c)])
        #expect(plan.layout.collected == [b, c] && plan.layout.resident == [a])
        #expect(Set(plan.patch.keys) == [b] && plan.patch[b]! > positions[c]!)
        let merged = try MenuBarSystemPositions.merging(positions, replacements: plan.patch, expected: source.expectation)
        #expect(merged.filter { $0.key != b } == positions.filter { $0.key != b })
        let reordered = try source.applying([.init(itemID: b, zone: .resident, beforeID: a)])
        #expect(reordered.layout.resident == [b, a] && reordered.patch[b]! < 400 && reordered.patch[b]! > 300)
        #expect(throws: MenuBarArrangementError.self) { try source.applying([.init(itemID: b, zone: .resident, beforeID: "missing")]) }
        var external = positions; external[a] = 350
        #expect(throws: MenuBarArrangementError.self) { try MenuBarSystemPositions.merging(external, replacements: plan.patch, expected: source.expectation) }
    }

    @Test("真实控制路径使用注入位置表，应用与撤销回读成功，原生外部状态不被测试触碰")
    @MainActor func applyAndUndo() async throws {
        var storage = positions
        let source = inventory()
        var writes = 0
        let model = MenuBarArrangementModel(collection: .preview(["app.c"]), owner: owner, capture: { MainActor.assertIsolated(); return source }, readPositions: { storage }, writePositions: { patch, expected in
            storage = try MenuBarSystemPositions.merging(storage, replacements: patch, expected: expected); writes += 1
        })
        try model.load(source, positions: storage)
        model.move(b, to: .collected, before: c)
        #expect(model.canApply && storage == positions)
        model.apply(); await model.finish()
        #expect(writes == 1 && model.error == nil && model.canUndo && !model.hasChanges)
        #expect(model.draft.collected == [b, c])
        model.undoLastApply(); await model.finish()
        #expect(writes == 2 && storage == positions && !model.canUndo && model.error == nil)
    }

    @Test("用户在面板外改顺序或应用重启后拒绝旧草稿，拒绝前不写位置表")
    @MainActor func staleDraftDoesNotWrite() async throws {
        var storage = positions
        var source = inventory()
        var writes = 0
        let model = MenuBarArrangementModel(collection: .preview(["app.c"]), owner: owner, capture: { MainActor.assertIsolated(); return source }, readPositions: { storage }, writePositions: { _, _ in writes += 1 })
        try model.load(source, positions: storage)
        model.move(b, to: .collected)
        storage[b] = 350
        model.apply(); await model.finish()
        #expect(writes == 0 && model.isStale)
        storage = positions
        try model.load(source, positions: storage)
        model.move(b, to: .collected)
        source = inventory([item("app.a"), item("app.b", pid: 9001), item("app.c")])
        model.apply(); await model.finish()
        #expect(writes == 0 && model.isStale)
    }
    @Test("同一应用跨区一起移动，区内仍能逐项排序")
    @MainActor func applicationScopedMove() throws {
        var values = positions
        values["status:app.multi::first"] = 120
        values["status:app.multi::second"] = 150
        let model = MenuBarArrangementModel(collection: .preview(), isPreview: true, owner: owner)
        try model.load(inventory([item("app.multi", id: "first"), item("app.multi", id: "second")]), positions: values)
        model.move("status:app.multi::first", to: .collected)
        #expect(model.draft.resident.isEmpty && model.draft.collected.count == 2)
        let original = model.draft.collected
        model.shift(original[1], in: .collected, by: -1)
        #expect(model.draft.collected == original.reversed())
    }

    @Test("root 图标按唯一系统键编排，原生动作仍要求启动身份；输入法菜单可编排")
    func persistentTargetsWithoutLaunchDate() throws {
        let rootKey = "status:app.root::Item-0"
        let inputKey = "status:com.apple.TextInputMenuAgent::Item-0"
        var values = positions; values[rootKey] = 150; values[inputKey] = 160
        var root = MenuBarObservedItem(id: UUID(), processID: 1001, processLaunchDate: nil,
            bundleIdentifier: "app.root", applicationName: "Root App", accessibilityIdentifier: nil,
            frame: nil, displayID: nil, declaresPress: true, declaresShowMenu: false, positionSettable: false)
        let input = item("com.apple.TextInputMenuAgent", id: "Item-0")
        let source = try MenuBarArrangementSnapshot(inventory: inventory([root, input]), positions: values, owner: owner, collectedApplications: ["app.c"])
        #expect(source.items.allSatisfy { $0.isEditable })
        #expect(!root.supportsActivation)
        let plan = try source.applying([.init(itemID: rootKey, zone: .collected, beforeID: nil)])
        #expect(plan.layout.collected == [rootKey] && plan.layout.resident == [inputKey])
        root.identityEligible = false
        let incomplete = try MenuBarArrangementSnapshot(inventory: inventory([root, input]), positions: values, owner: owner, collectedApplications: ["app.c"])
        #expect(incomplete.items.first { $0.observed.bundleIdentifier == "app.root" }?.isEditable == false)
    }

    @Test("Cmd重排只改变各组顺序，不改变收纳名单；行内切换不写系统位置")
    @MainActor func membershipSurvivesNativeReordering() async throws {
        var native = positions
        native[a] = 40; native[b] = 20; native[c] = 10
        native.removeValue(forKey: "status:test.owner::menu-bar.group-v3.toggle")
        native.removeValue(forKey: "status:test.owner::menu-bar.group-v3.hidden")
        let source = inventory()
        let access = MenuBarCollectionAccess.preview(["app.c"])
        var writes = 0
        let model = MenuBarArrangementModel(collection: access, owner: owner, capture: { source }, readPositions: { native }, writePositions: { _, _ in writes += 1 })
        try model.load(source, positions: native)
        #expect(model.draft.collected == [c])
        model.setZone(a, to: .collected)
        model.apply(); await model.finish()
        #expect(model.error == nil && writes == 0 && model.draft.collected == [a, c])
        #expect(try access.read() == ["app.a", "app.c"])
        native[c] = 100
        // 用注入快照验证重排；真实刷新入口仅支持 macOS 27，不能让 CI 宿主版本决定夹具结果。
        try model.load(source, positions: native)
        #expect(model.draft.collected == [c, a])
        model.undoLastApply(); await model.finish()
        #expect(model.error == nil && writes == 0 && model.draft.collected == [c])
        #expect(try access.read() == ["app.c"])
    }

    @Test("名单保存失败不写排序；排序冲突会补偿本次名单提交")
    @MainActor func collectionCommitFailure() async throws {
        let source = inventory(), native = positions
        var selected: Set<String> = ["app.c"]
        var failSave = true, positionWrites = 0
        let access = MenuBarCollectionAccess(read: { selected }, write: { next, expected in
            guard !failSave, selected == expected else { throw MenuBarArrangementError.unavailable }
            selected = next
        })
        let model = MenuBarArrangementModel(collection: access, owner: owner, capture: { source }, readPositions: { native }, writePositions: { _, _ in
            positionWrites += 1; throw MenuBarArrangementError.changed
        })
        try model.load(source, positions: native); model.move(a, to: .collected, before: c)
        model.apply(); await model.finish()
        #expect(selected == ["app.c"] && positionWrites == 0 && model.error != nil)
        failSave = false
        try model.load(source, positions: native); model.move(a, to: .collected, before: c)
        model.apply(); await model.finish()
        #expect(selected == ["app.c"] && positionWrites == 1 && model.error != nil)
    }

}
