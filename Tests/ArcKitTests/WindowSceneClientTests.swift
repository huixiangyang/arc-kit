@testable import ArcKitApplication
import ArcKitPlatform
import ArcKitWindow
import Foundation
import Testing

@Suite("窗口场景客户端", .serialized)
@MainActor
struct WindowSceneClientTests {
    @Test("后发健康查询先返回不能吞掉场景完成报告，失败释放执行状态")
    func completionAfterHealthReply() throws {
        let fixture = SceneClientFixture()
        fixture.connect()
        let service = WindowManagementService(bridge: fixture.client)
        let sceneID = UUID(), token = UUID()
        service.applyScene(id: sceneID)
        service.applyScene(id: UUID())
        #expect(service.isApplyingScene && fixture.requests.count == 1)
        let request = fixture.requests[0]
        #expect(request.operation == .applyScene && request.sceneID == sceneID)
        #expect(request.targetID == nil && request.action == nil && request.undoToken == nil)
        #expect(request.sessionID == fixture.context.sessionID && request.revision == fixture.context.revision)
        try request.validate()

        fixture.client.refresh()
        fixture.respond(1, state: fixture.state)
        let report = WindowSceneExecutionReport(sceneID: sceneID, sceneName: "Develop",
            items: [.init(entryID: UUID(), status: .applied)], undoToken: token)
        var completed = fixture.state
        completed.lastSceneResult = report
        fixture.respond(0, state: completed, report: report)
        #expect(!service.isApplyingScene && service.lastSceneError == nil)
        #expect(service.lastSceneResult == report && fixture.client.snapshot.lifecycle == .running)
        // Host 的一份稍旧状态不得覆盖刚收到的实际执行结果。
        fixture.client.receive(fixture.state)
        #expect(service.lastSceneResult == report)

        service.undoScene(token: token)
        #expect(service.isApplyingScene && fixture.requests[2].undoToken == token)
        #expect(fixture.requests[2].sceneID == nil && fixture.requests[2].operation == .undoScene)
        fixture.completions[2](.failure(.connectionFailed("fixture transport failure")))
        #expect(!service.isApplyingScene && service.lastSceneError != nil)
    }

    @Test("新配置和Host重启隔离旧场景回包，失效枚举不得进入编辑器")
    func staleSessionCannotRestoreReport() {
        let fixture = SceneClientFixture()
        fixture.connect()
        let service = WindowManagementService(bridge: fixture.client)
        service.applyScene(id: UUID())
        let oldReport = WindowSceneExecutionReport(sceneID: fixture.requests[0].sceneID!, sceneName: "Old",
            items: [.init(entryID: UUID(), status: .applied)], undoToken: UUID())
        let nextContext = RuntimeRequestContext(sessionID: fixture.context.sessionID, revision: 2)
        fixture.client.configure(context: nextContext)
        var newState = fixture.state
        newState.launchID = UUID()
        fixture.client.receive(newState)
        var oldState = fixture.state
        oldState.lastSceneResult = oldReport
        fixture.respond(0, state: oldState, report: oldReport)
        #expect(!service.isApplyingScene && service.lastSceneError != nil)
        #expect(fixture.client.snapshot.launchID == newState.launchID && service.lastSceneResult == nil)

        var rejected = false
        fixture.client.fetchSceneInventory { result in
            if case .failure = result { rejected = true }
        }
        fixture.completions[1](.success(.init(requestID: fixture.requests[1].requestID, state: newState,
            sceneInventory: .init(hostLaunchID: fixture.state.launchID, displays: [], candidates: []))))
        #expect(rejected && fixture.client.snapshot.launchID == newState.launchID)

        fixture.client.configure(context: nil)
        var unavailable = false
        fixture.client.fetchSceneInventory { result in
            if case .failure = result { unavailable = true }
        }
        #expect(unavailable && fixture.requests.count == 2)
    }
}

@MainActor
private final class SceneClientFixture {
    let context = RuntimeRequestContext(sessionID: UUID(), revision: 1)
    var state = WindowAgentRuntimeSnapshot(lifecycle: .running, processID: 123, launchID: UUID(),
        accessibilityTrusted: true, accessibilityOperational: true)
    var requests: [WindowAgentRequest] = []
    var completions: [WindowAgentXPCClient.Completion] = []
    lazy var client = WindowRuntimeClient(sender: { [unowned self] request, completion in
        requests.append(request)
        completions.append(completion)
    }, disconnect: {})

    func connect() {
        client.configure(context: context)
        client.receive(state)
    }

    func respond(_ index: Int, state: WindowAgentRuntimeSnapshot, report: WindowSceneExecutionReport? = nil) {
        completions[index](.success(.init(requestID: requests[index].requestID, state: state, sceneResult: report)))
    }
}
