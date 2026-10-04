import ArcKitPlatform
import ArcKitWindow
import CoreGraphics
import Foundation
import Testing

@Suite("窗口场景身份与布局")
struct WindowSceneDomainTests {
    @Test("负坐标副屏按可用区域比例恢复，拒绝非有限和完全离屏几何")
    func relativeGeometry() throws {
        let saved = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
        let window = CGRect(x: -1920, y: -200, width: 1248, height: 1000)
        let frame = try WindowSceneNormalizedFrame.capture(frame: window, visibleFrame: saved)
        let restored = try frame.resolve(in: CGRect(x: -2560, y: 25, width: 2560, height: 1400))
        #expect(restored == CGRect(x: -2560, y: 25, width: 1664, height: 1400))
        #expect(throws: WindowSceneValidationError.invalidGeometry) {
            try WindowSceneNormalizedFrame(x: .nan, y: 0, width: 1, height: 1).validate()
        }
        #expect(throws: WindowSceneValidationError.invalidGeometry) {
            try WindowSceneNormalizedFrame(x: 1, y: 0, width: 0.5, height: 1).validate()
        }
        #expect(throws: WindowSceneValidationError.invalidGeometry) {
            try WindowSceneNormalizedFrame(x: 0, y: 0, width: 1e200, height: 1).validate()
        }
    }

    @Test("原窗口改名仍匹配，同进程关闭后同名新窗不能冒充，应用重启才按规则匹配")
    func sessionIdentityAndRestart() throws {
        var fixture = try SceneFixture()
        fixture.candidate.title = "Renamed document"
        #expect(try fixture.plan().first?.candidateID == fixture.candidate.id)

        // 同一个应用进程的新窗口，即使标题相同，也不是刚刚捕获的窗口。
        fixture.candidate.id = UUID()
        fixture.candidate.sessionHint?.capturedWindowID = fixture.candidate.id
        fixture.candidate.title = fixture.scene.entries[0].titleMatchValue
        #expect(try fixture.plan().first?.status == .missingWindow)

        // PID 被复用时还必须核对应用启动时间，只有新实例才允许重新走标题规则。
        fixture.candidate.sessionHint?.applicationLaunchDate = Date(timeIntervalSince1970: 200)
        #expect(try fixture.plan().first?.candidateID == fixture.candidate.id)
        fixture.candidate.bundleIdentifier = "test.other"
        #expect(try fixture.plan().first?.status == .missingWindow)

        fixture.candidate.bundleIdentifier = fixture.scene.entries[0].bundleIdentifier
        fixture.hostLaunchID = UUID()
        fixture.candidate.sessionHint?.hostLaunchID = fixture.hostLaunchID
        fixture.candidate.title = "Unrelated document"
        #expect(try fixture.plan().first?.status == .missingWindow)
    }

    @Test("跨启动只接受唯一匹配，缺屏不挤主屏，竞争窗口的所有条目都拒绝")
    func ambiguityMissingDisplayAndAssignmentConflict() throws {
        var fixture = try SceneFixture()
        fixture.scene.entries[0].sessionHint = nil
        fixture.scene.entries[0].titleMatchMode = .contains
        fixture.scene.entries[0].titleMatchValue = "project"
        var other = fixture.candidate
        other.id = UUID()
        other.title = "Project notes"
        var inventory = fixture.inventory
        inventory.candidates.append(other)
        let ambiguous = try WindowSceneMatcher.plan(scene: fixture.scene, inventory: inventory)
        #expect(ambiguous[0].status == .ambiguousWindow)
        #expect(Set(ambiguous[0].candidateIDs) == [fixture.candidate.id, other.id])

        var second = fixture.scene.entries[0]
        second.id = UUID()
        fixture.scene.entries.append(second)
        #expect(try fixture.plan().map(\.status) == [.conflictingAssignment, .conflictingAssignment])
        #expect(try fixture.plan().allSatisfy { $0.candidateID == nil && $0.targetFrame == nil })

        fixture.scene.entries.removeLast()
        inventory = fixture.inventory
        inventory.displays[0].id = UUID().uuidString
        #expect(try WindowSceneMatcher.plan(scene: fixture.scene, inventory: inventory)[0].status == .missingDisplay)
    }

    @Test("持久化拒绝坏引用、自身应用和超额窗口，旧窗口JSON不静默补字段")
    func strictConfigurationValidation() throws {
        let fixture = try SceneFixture()
        var scene = fixture.scene
        scene.focusEntryID = UUID()
        #expect(throws: WindowSceneValidationError.invalidFocus) { try scene.validate() }
        scene = fixture.scene
        scene.entries[0].bundleIdentifier = ArcKitConstants.appBundleIdentifier
        #expect(throws: WindowSceneValidationError.invalidEntry) { try scene.validate() }
        scene = fixture.scene
        scene.entries = (0...WindowScene.maximumEntryCount).map { _ in
            var entry = fixture.scene.entries[0]
            entry.id = UUID()
            return entry
        }
        #expect(throws: WindowSceneValidationError.tooManyEntries) { try scene.validate() }
        var settings = WindowManagementSettings(scenes: [fixture.scene])
        #expect(try JSONDecoder().decode(WindowManagementSettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.scenes.append(fixture.scene)
        #expect(throws: WindowSceneValidationError.duplicateIdentity) {
            try JSONDecoder().decode(WindowManagementSettings.self, from: JSONEncoder().encode(settings))
        }
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(WindowManagementSettings.defaults)) as? [String: Any])
        old.removeValue(forKey: "scenes")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WindowManagementSettings.self, from: JSONSerialization.data(withJSONObject: old))
        }
    }

    private struct SceneFixture {
        var hostLaunchID: UUID
        var display: WindowSceneDisplay
        var candidate: WindowSceneCandidate
        var scene: WindowScene

        init() throws {
            hostLaunchID = UUID()
            display = .init(id: UUID().uuidString, name: "External", visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
            let windowID = UUID()
            candidate = .init(id: windowID, bundleIdentifier: "test.editor", applicationName: "Editor", title: "Project",
                              displayID: display.id, frame: CGRect(x: -1920, y: 0, width: 960, height: 1080),
                              sessionHint: .init(hostLaunchID: hostLaunchID, capturedWindowID: windowID,
                                                 processIdentifier: 100, applicationLaunchDate: Date(timeIntervalSince1970: 100), windowNumber: 5))
            let entry = try WindowSceneEntry.capture(candidate: candidate, display: display)
            scene = .init(name: "Develop", displays: [display], entries: [entry], focusEntryID: entry.id)
        }

        var inventory: WindowSceneInventory { .init(hostLaunchID: hostLaunchID, displays: [display], candidates: [candidate]) }
        func plan() throws -> [WindowScenePlannedEntry] { try WindowSceneMatcher.plan(scene: scene, inventory: inventory) }
    }
}
