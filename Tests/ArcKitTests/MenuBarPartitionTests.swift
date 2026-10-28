@testable import ArcKitApplication
import ApplicationServices
import Foundation
import Testing

@Suite("菜单栏分区凭据")
struct MenuBarPartitionTests {
    @Test("恢复确认要求连续稳定屏幕和真实占位宽度，缺失或旧读数重新等待")
    func revealedLayoutStability() {
        var confirmation = MenuBarRevealConfirmation()
        let widths: [CGFloat] = [18, 18, 0]
        let oldWidth = confirmation.observe(displays: Self.displays, expectedWidths: widths, actualWidths: [18, 18, 267])
        #expect(!oldWidth)
        let firstMatch = confirmation.observe(displays: Self.displays, expectedWidths: widths, actualWidths: [18, 18, 0])
        #expect(!firstMatch)
        let missingScreen = confirmation.observe(displays: nil, expectedWidths: widths, actualWidths: [18, 18, 0])
        #expect(!missingScreen)
        let missingButton = confirmation.observe(displays: Self.displays, expectedWidths: widths, actualWidths: [18, 18, nil])
        #expect(!missingButton)
        let recoveredButton = confirmation.observe(displays: Self.displays, expectedWidths: widths, actualWidths: [18, 18, 0])
        #expect(!recoveredButton)
        let singleDisplay = Array(Self.displays.prefix(1))
        let changedScreen = confirmation.observe(displays: singleDisplay, expectedWidths: widths, actualWidths: [18, 18, 0])
        #expect(!changedScreen)
        let settled = confirmation.observe(displays: singleDisplay, expectedWidths: widths, actualWidths: [18, 18, 0])
        #expect(settled)
    }

    @Test("收起确认必须有离屏边界，不能把合法的展开布局当作收起成功")
    func presentationReadback() throws {
        let expanded = try Self.layout()
        #expect(expanded.confirmsHiddenSections(for: .all))
        #expect(!expanded.confirmsHiddenSections(for: .collapsed))
        #expect(!expanded.confirmsHiddenSections(for: .expanded))
        let collapsed = try MenuBarPartitionSnapshot(generation: 2, displays: Self.displays,
            control: Self.rect(1300), hidden: CGRect(x: -1700, y: 4, width: 2800, height: 22),
            deep: CGRect(x: -4600, y: 4, width: 2800, height: 22))
        #expect(collapsed.confirmsHiddenSections(for: .collapsed))
        #expect(!collapsed.confirmsHiddenSections(for: .expanded))
        let ordinary = try MenuBarPartitionSnapshot(generation: 3, displays: Self.displays,
            control: Self.rect(1300), hidden: Self.rect(1100),
            deep: CGRect(x: -1900, y: 4, width: 2800, height: 22))
        #expect(ordinary.confirmsHiddenSections(for: .expanded))
        #expect(!ordinary.confirmsHiddenSections(for: .all))
    }

    @Test("展开与收起均按完整边界分类，负坐标与其他显示器不能混入")
    func sectionGeometry() throws {
        let layout = try Self.layout()
        #expect(layout.section(frame: Self.rect(1200)) == .visible)
        #expect(layout.section(frame: Self.rect(1000)) == .collected)
        #expect(layout.section(frame: Self.rect(800)) == .deep)
        #expect(layout.section(frame: Self.rect(1090)) == .unknown)
        #expect(layout.section(frame: nil) == .unknown)
        #expect(layout.section(frame: CGRect(x: -1000, y: -995, width: 22, height: 22)) == .otherDisplay)
        let collapsed = try MenuBarPartitionSnapshot(generation: 2, displays: Self.displays,
            control: Self.rect(1300), hidden: CGRect(x: -4000, y: 4, width: 5100, height: 22),
            deep: CGRect(x: -9200, y: 4, width: 5100, height: 22))
        #expect(collapsed.section(frame: Self.rect(-4080)) == .collected)
        #expect(collapsed.section(frame: Self.rect(-9300)) == .deep)
        let collinear = MenuBarDisplay(id: 3, name: "Left", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
            topBand: CGRect(x: -1440, y: 0, width: 1440, height: 32), notch: nil, scale: 1)
        let ambiguous = try MenuBarPartitionSnapshot(generation: 2, displays: Self.displays + [collinear],
            control: Self.rect(1300), hidden: CGRect(x: -500, y: 4, width: 1600, height: 22),
            deep: CGRect(x: -2000, y: 4, width: 1000, height: 22))
        #expect(ambiguous.section(frame: Self.rect(-900)) == .unknown)
        #expect(throws: MenuBarPartitionError.self) {
            try MenuBarPartitionSnapshot(generation: 0, displays: Self.displays,
                control: Self.rect(1300), hidden: Self.rect(1100), deep: Self.rect(1200))
        }
        // 状态项离屏坐标可能投影到另一显示器的桌面内部，不等于属于那块屏幕的菜单栏。
        let upper = MenuBarDisplay(id: 2, name: "Upper", frame: CGRect(x: -554, y: -1440, width: 2560, height: 1440),
            topBand: CGRect(x: -554, y: -1440, width: 2560, height: 22), notch: nil, scale: 1)
        let right = MenuBarDisplay(id: 3, name: "Right", frame: CGRect(x: 2006, y: -1080, width: 1920, height: 1080),
            topBand: CGRect(x: 2006, y: -1080, width: 1920, height: 22), notch: nil, scale: 1)
        let shifted = try MenuBarPartitionSnapshot(generation: 1, displays: [upper, right],
            control: CGRect(x: 3850, y: -1076, width: 18, height: 22),
            hidden: CGRect(x: -100, y: -1076, width: 3600, height: 22),
            deep: CGRect(x: -5200, y: -1076, width: 5000, height: 22))
        let frame = CGRect(x: -180, y: -1076, width: 22, height: 22)
        #expect(MenuBarDisplay.containing(frame, in: [upper, right]) == 2)
        #expect(shifted.section(frame: frame) == .collected)
    }

    @Test("普通收纳不搜索深度与未知项目，布局变更和缺失不降级为全部图标")
    @MainActor func scopeFiltering() throws {
        let layout = try Self.layout()
        let normal = Self.item("Collected", x: 1000)
        let deep = Self.item("Private", x: 800)
        let unknown = Self.item("Unknown", x: 1090)
        let inventory = MenuBarInventory(id: UUID(), capturedAt: Date(), systemVersion: "Fixture", accessibility: .granted,
            displays: Self.displays, items: [normal, deep, unknown], issues: [])
        let model = MenuBarShelfModel()
        model.scope = .collected
        model.load(inventory, partition: layout, targetDisplayID: 1)
        #expect(model.filteredItems.map(\.id) == [normal.id] && model.unclassifiedCount == 1)
        model.query = "Private"
        #expect(model.filteredItems.isEmpty)
        model.scope = .all
        #expect(model.filteredItems.map(\.id) == [deep.id])
        var actions = 0
        model.onActivate = { _, _ in actions += 1 }
        model.scope = .collected
        model.activate(deep.id)
        #expect(actions == 0 && model.selectedID == nil)
        model.query = ""
        model.load(inventory)
        #expect(model.scopeError != nil && model.filteredItems.isEmpty)
        model.scope = .all
        #expect(model.scopeError == nil && model.filteredItems.count == 3)
        #expect(MenuBarPartitionSnapshot.validated(before: layout, after: try Self.layout(generation: 2), inventory: inventory, targetDisplayID: 1) == nil)
        #expect(MenuBarPartitionSnapshot.validated(before: layout, after: layout, inventory: inventory, targetDisplayID: 2) == nil)
    }

    @Test("普通区取用再次读取原对象位置与当前布局，移动到深度区或布局失效时不发送")
    @MainActor func liveCollectionConstraint() throws {
        let layout = try Self.layout()
        let item = Self.item("Collected", x: 1000)
        var liveFrame = Self.rect(800)
        var current = true
        var sends = 0
        let access = MenuBarItemAccessSession(isTrusted: { true }, process: { _ in
            .init(processID: item.processID, launchDate: item.processLaunchDate!, bundleIdentifier: item.bundleIdentifier)
        }, currentDisplays: { Self.displays })
        let observation = UUID()
        access.begin(id: observation, displays: Self.displays)
        access.add(.init(item: item, read: { includeFrame in
            #expect(includeFrame)
            return .init(frame: liveFrame, isMenuBarItem: true, actions: [kAXPressAction])
        }, perform: { _ in sends += 1; return 0 }))
        let constraint = MenuBarCollectionConstraint(snapshot: layout, isCurrent: { current })
        #expect(throws: MenuBarItemAccessError.sectionChanged) {
            try access.activate(itemID: item.id, inventoryID: observation, displayID: 1, collection: constraint)
        }
        liveFrame = Self.rect(1000); current = false
        #expect(throws: MenuBarItemAccessError.sectionChanged) {
            try access.activate(itemID: item.id, inventoryID: observation, displayID: 1, collection: constraint)
        }
        #expect(sends == 0)
        current = true
        try access.activate(itemID: item.id, inventoryID: observation, displayID: 1, collection: constraint)
        #expect(sends == 1)
    }

    private static var displays: [MenuBarDisplay] {
        [.init(id: 1, name: "Fixture", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
               topBand: CGRect(x: 0, y: 0, width: 1440, height: 32), notch: nil, scale: 2),
         .init(id: 2, name: "Other", frame: CGRect(x: -1920, y: -1000, width: 1920, height: 1000),
               topBand: CGRect(x: -1920, y: -1000, width: 1920, height: 32), notch: nil, scale: 1)]
    }
    private static func layout(generation: Int = 1) throws -> MenuBarPartitionSnapshot {
        try .init(generation: generation, displays: displays, control: rect(1300), hidden: rect(1100), deep: rect(900))
    }
    private static func rect(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 4, width: 22, height: 22) }
    private static func item(_ name: String, x: CGFloat) -> MenuBarObservedItem {
        .init(id: UUID(), processID: 900001, processLaunchDate: Date(timeIntervalSince1970: 100), bundleIdentifier: "fixture",
              applicationName: name, accessibilityIdentifier: nil, frame: rect(x), displayID: nil,
              declaresPress: true, declaresShowMenu: false, positionSettable: false)
    }
}
