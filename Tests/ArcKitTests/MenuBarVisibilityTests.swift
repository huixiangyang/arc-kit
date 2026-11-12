import Foundation
import Testing
@testable import ArcKitApplication

@Suite("菜单栏直接隐藏")
struct MenuBarVisibilityTests {
    @Test("系统显示条目必须唯一且不能夹带其他应用")
    func registryIdentity() throws {
        let location = ["bundle": ["_0": "test.app"]]
        let row: [String: Any] = ["location": location, "isAllowed": true, "menuItemLocations": [location]]
        #expect(try MenuBarVisibilityStore.allowed("test.app", in: [location, row]))
        #expect(MenuBarVisibilityStore.collectionRestriction(for: "test.app", in: [location, row]) == nil)
        #expect(throws: MenuBarVisibilityError.self) { try MenuBarVisibilityStore.allowed("test.app", in: [location, row, location, row]) }
        var mixed = row; mixed["menuItemLocations"] = [location, ["bundle": ["_0": "other.app"]]]
        #expect(throws: MenuBarVisibilityError.self) { try MenuBarVisibilityStore.allowed("test.app", in: [location, mixed]) }
        #expect(MenuBarVisibilityStore.collectionRestriction(for: "test.app", in: [location, mixed]) == .linkedApplications)
        #expect(MenuBarVisibilityStore.collectionRestriction(for: "missing", in: [location, row]) == .unavailable)
    }

    @Test("只收纳整组、正在运行的应用；保留品牌与固定系统项，输入法菜单可参与")
    @MainActor func targetPlan() throws {
        let selected: Set<String> = ["one", "stopped", "owner", "com.apple.TextInputMenuAgent", "com.apple.MenuBarAgent"]
        let running: Set<String> = ["one", "two", "owner", "com.apple.TextInputMenuAgent", "com.apple.MenuBarAgent"]
        #expect(MenuBarVisibilitySession.hiddenBundles(collectedApplications: selected, owner: "owner", running: running) == ["one", "com.apple.TextInputMenuAgent"])

    }
    @Test("输入菜单与应用共用按令牌恢复；不改无关偏好或用户原本隐藏的目标")
    func inputMenuRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("applications").path
        let inputDomain = root.appendingPathComponent("input").path
        let bundle = "example.app", other = "example.other"
        func row(_ bundle: String, allowed: Bool) -> [Any] {
            let location = ["bundle": ["_0": bundle]]
            return [location, ["location": location, "menuItemLocations": [location], "isAllowed": allowed] as [String: Any]]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: row(bundle, allowed: true) + row(other, allowed: false), format: .binary, options: 0)
        CFPreferencesSetAppValue("trackedApplications" as CFString, data as CFData, applications as CFString)
        #expect(CFPreferencesAppSynchronize(applications as CFString))
        CFPreferencesSetAppValue("visible" as CFString, kCFBooleanTrue, inputDomain as CFString)
        CFPreferencesSetAppValue("unrelated" as CFString, "keep" as CFString, inputDomain as CFString)
        #expect(CFPreferencesAppSynchronize(inputDomain as CFString))
        let input = MenuBarInputMenu(domain: inputDomain)
        let store = MenuBarVisibilityStore(domain: applications, inputMenu: input)
        let recovery = MenuBarVisibilityRecovery(file: root.appendingPathComponent("recovery.json"))
        let token = UUID(), inputID = MenuBarInputMenu.bundleIdentifier
        try recovery.write(.init(token: token, bundles: [bundle, inputID]))
        try store.set([bundle: false, inputID: false])
        #expect(try store.snapshot([bundle, inputID]) == [bundle: false, inputID: false])
        try recovery.restore(token: UUID(), visibility: store)
        #expect(try !input.isVisible())
        try recovery.restore(token: token, visibility: store)
        #expect(try store.snapshot([bundle, other, inputID]) == [bundle: true, other: false, inputID: true])
        #expect(try recovery.read() == nil)
        #expect(CFPreferencesCopyAppValue("unrelated" as CFString, inputDomain as CFString) as? String == "keep")
        try input.setVisible(false)
        try recovery.write(.init(token: token, bundles: [bundle]))
        try store.set([bundle: false])
        try recovery.restore(token: token, visibility: store)
        #expect(try !input.isVisible())
    }

}
