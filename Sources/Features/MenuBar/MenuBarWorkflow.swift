import ArcKitPlatform
import Combine
import Foundation

/// 只处理主开关保存和预览状态，不再维护“开始整理／完成整理”的第二套流程。
@MainActor
final class MenuBarWorkflow: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var error: String?
    @Published private var previewPresentation: MenuBarPresentation = .all
    private let editor: SettingsEditor<MenuBarSettings>
    private let service: MenuBarManagementService
    private var generation = 0
    private var lastRequestedEnabled = false

    init(editor: SettingsEditor<MenuBarSettings>, service: MenuBarManagementService) {
        self.editor = editor; self.service = service
    }
    var presentation: MenuBarPresentation { service.isPreview ? previewPresentation : service.requestedPresentation }
    func retry() async { await setEnabled(lastRequestedEnabled) }
    func leave() { generation += 1; isWorking = false }

    func setEnabled(_ enabled: Bool) async {
        guard !isWorking else { return }
        lastRequestedEnabled = enabled
        generation += 1
        let request = generation
        isWorking = true; error = nil
        defer { if generation == request { isWorking = false } }
        editor.update(actionName: L10n.string(enabled ? .MenuBar.flowEnable : .MenuBar.flowDisable)) { $0.isEnabled = enabled }
        let saved = await editor.commitPendingChanges()
        guard generation == request else { return }
        guard saved else { error = editor.failureMessage ?? L10n.string(.MenuBar.flowSaveFailed); return }
        // 正式服务在消费已提交开关时创建或撤除控件；页面不再追加另一次原生动作。
        previewPresentation = .all
    }

    func toggle() {
        guard !isWorking, editor.committedSettings?.isEnabled == true else { return }
        error = nil
        if service.isPreview {
            previewPresentation = previewPresentation == .collapsed ? .all : .collapsed
        } else { service.toggleCollection() }
    }
    func showAll() {
        error = nil
        if service.isPreview { previewPresentation = .all }
        else { service.present(.all) }
    }
}
