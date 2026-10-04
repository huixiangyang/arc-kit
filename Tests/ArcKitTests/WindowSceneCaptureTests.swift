@testable import ArcKitApplication
import ArcKitWindow
import CoreGraphics
import Foundation
import Testing

@Suite("窗口场景布局更新")
struct WindowSceneCaptureTests {
    @Test("只移除明确取消的已匹配窗口，保留缺失条目及规则，并拒绝失效选择")
    func updatePreservesUnavailableEntriesAndUserRules() throws {
        let main = WindowSceneDisplay(id: "main", name: "Main", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let side = WindowSceneDisplay(id: "side", name: "Side", visibleFrame: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let host = UUID()
        let editorID = UUID()
        let editorHint = WindowSceneSessionHint(hostLaunchID: host, capturedWindowID: editorID, processIdentifier: 101)
        let editor = WindowSceneEntry(bundleIdentifier: "test.editor", applicationName: "Editor", savedTitle: "Old project title",
                                      titleMatchMode: .contains, titleMatchValue: "Project", displayID: main.id,
                                      normalizedFrame: .init(x: 0, y: 0, width: 0.6, height: 1), sessionHint: editorHint)
        let browser = WindowSceneEntry(bundleIdentifier: "test.browser", applicationName: "Browser", savedTitle: "Docs",
                                       titleMatchMode: .exact, titleMatchValue: "Docs", displayID: main.id,
                                       normalizedFrame: .init(x: 0.6, y: 0, width: 0.4, height: 1))
        let missing = WindowSceneEntry(bundleIdentifier: "test.terminal", applicationName: "Terminal", savedTitle: "Build",
                                       titleMatchMode: .contains, titleMatchValue: "Build", displayID: side.id,
                                       normalizedFrame: .init(x: 0, y: 0, width: 1, height: 0.5))
        let scene = WindowScene(name: "Development", displays: [main, side], entries: [editor, browser, missing], focusEntryID: editor.id,
                                shortcut: .init(keyCode: 18, keyEquivalent: "1", modifiers: [.control, .option, .command]))
        let currentEditor = WindowSceneCandidate(id: editorID, bundleIdentifier: editor.bundleIdentifier, applicationName: "Editor",
                                                title: "Project — Updated", displayID: main.id,
                                                frame: CGRect(x: 100, y: 80, width: 500, height: 640), sessionHint: editorHint)
        let currentBrowser = WindowSceneCandidate(bundleIdentifier: browser.bundleIdentifier, applicationName: "Browser", title: "Docs",
                                                 displayID: main.id, frame: CGRect(x: 600, y: 0, width: 400, height: 800))
        let inventory = WindowSceneInventory(hostLaunchID: host, displays: [main], candidates: [currentEditor, currentBrowser])
        let updated = try WindowSceneCapture.update(scene: scene, inventory: inventory, selectedIDs: [editorID])
        try updated.validate()
        #expect(updated.id == scene.id && updated.name == scene.name && updated.shortcut == scene.shortcut)
        #expect(updated.focusEntryID == editor.id)
        #expect(updated.entries.map(\.id) == [editor.id, missing.id])
        #expect(updated.entries.last == missing)
        #expect(updated.displays == [main, side])
        let updatedEditor = try #require(updated.entries.first)
        #expect(updatedEditor.titleMatchMode == .contains && updatedEditor.titleMatchValue == "Project")
        #expect(updatedEditor.savedTitle == currentEditor.title)
        #expect(updatedEditor.normalizedFrame == .init(x: 0.1, y: 0.1, width: 0.5, height: 0.8))
        #expect(WindowSceneCapture.preservedEntries(scene: scene, inventory: inventory) == [missing])
        #expect(throws: WindowSceneClientError.self) {
            try WindowSceneCapture.update(scene: scene, inventory: inventory, selectedIDs: [UUID()])
        }
    }
}
