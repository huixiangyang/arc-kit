import ArcKitPlatform
import CoreGraphics
import Foundation
import Testing
@testable import ArcKitApplication

@Suite("菜单栏身份与外观几何")
struct MenuBarInspectionTests {
    @Test("匿名、多实例冲突和遍历不完整不能冒充持久化身份")
    func identityCandidates() {
        var identified = item(bundle: "example.one", identifier: "status")
        identified.identityEligible = false
        var items = [item(bundle: "example.one", identifier: nil),
                     item(bundle: "example.one", identifier: "duplicate"),
                     item(bundle: "example.one", identifier: "duplicate"),
                     item(bundle: "example.two", identifier: "duplicate"), identified]
        MenuBarItemKey.assignUniqueCandidates(to: &items)
        #expect(items.map { $0.persistentKey != nil } == [false, false, false, true, false])
        // 再次计算必须清除旧结果；不能因之前唯一而保留已经冲突的候选。
        items.append(item(bundle: "example.two", identifier: "duplicate"))
        MenuBarItemKey.assignUniqueCandidates(to: &items)
        #expect(items.allSatisfy { $0.persistentKey == nil })
    }

    @Test("负坐标副屏和不可见图标不能套用主屏")
    func displayAssignment() {
        let displays = [display(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                        display(id: 2, frame: CGRect(x: -554, y: -1440, width: 2560, height: 1440))]
        #expect(MenuBarDisplay.containing(CGRect(x: 100, y: -1435, width: 24, height: 22), in: displays) == 2)
        #expect(MenuBarDisplay.containing(CGRect(x: -10000, y: 0, width: 24, height: 22), in: displays) == nil)
        #expect(MenuBarDisplay.containing(.zero, in: displays) == nil)
        let coordinates = ArcKitScreenCoordinateSpace(primaryScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(coordinates.appKitToAccessibility(CGRect(x: -554, y: 982, width: 2560, height: 1440)) == displays[1].frame)
    }

    @Test("悬浮与分段避开刘海，拥挤内容合并而非重叠染色")
    func appearanceRegions() {
        let bar = CGRect(x: -500, y: -100, width: 1000, height: 36)
        let notch = CGRect(x: -70, y: -100, width: 140, height: 30)
        for style in [MenuBarAppearanceStyle.floating, .split] {
            let regions = MenuBarAppearanceGeometry.regions(style: style, bar: bar, notch: notch, leadingWidth: 300, trailingWidth: 280)
            #expect(regions.count == 2)
            #expect(regions.allSatisfy { bar.contains($0) && !$0.intersects(notch) })
            #expect(!regions[0].intersects(regions[1]))
        }
        let crowded = MenuBarAppearanceGeometry.regions(style: .split, bar: bar, notch: nil, leadingWidth: 700, trailingWidth: 400)
        #expect(crowded == [bar.insetBy(dx: 4, dy: 4)])
        #expect(MenuBarAppearanceGeometry.regions(style: .native, bar: bar, notch: notch, leadingWidth: 0, trailingWidth: 0) == [bar])
    }

    @Test("坏几何不产生绘制区域，库存序列化保持系统事实")
    func invalidGeometryAndReport() throws {
        #expect(MenuBarAppearanceGeometry.regions(style: .split, bar: .zero, notch: nil, leadingWidth: 100, trailingWidth: 100).isEmpty)
        #expect(MenuBarAppearanceGeometry.regions(style: .floating, bar: CGRect(x: 0, y: 0, width: 100, height: 30), notch: nil, leadingWidth: .nan, trailingWidth: 10).isEmpty)
        let observation = MenuBarInventory(id: UUID(), capturedAt: Date(), systemVersion: "fixture", accessibility: .denied,
            displays: [], items: [], issues: [.init(kind: .permissionDenied, processID: nil, attribute: nil, errorCode: nil)])
        let decoded = try JSONDecoder().decode(MenuBarInventory.self, from: JSONEncoder().encode(observation))
        #expect(decoded.accessibility == .denied && decoded.items.isEmpty && !decoded.canUseGeometry)
    }

    private func item(bundle: String?, identifier: String?) -> MenuBarObservedItem {
        .init(id: UUID(), processID: 42, processLaunchDate: nil, bundleIdentifier: bundle, applicationName: "Fixture",
              accessibilityIdentifier: identifier, frame: nil, displayID: nil,
              declaresPress: true, declaresShowMenu: false, positionSettable: false)
    }
    private func display(id: UInt32, frame: CGRect) -> MenuBarDisplay {
        .init(id: id, name: "Fixture", frame: frame,
              topBand: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 24), notch: nil, scale: 1)
    }
}
