import AppKit
import ArcKitPlatform
import ArcKitWindow
import SwiftUI

/// 菜单的展开、焦点和取消交给 AppKit；自定义视图只承载功能控件。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let state = MenuBarPanelState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let clickSource = MenuBarClickSource()
    private let prepare: (AppConfigurationCandidate, @escaping (WindowTargetCaptureResult) -> Void) -> Void
    private var originPID: pid_t?
    private var hosting: NSHostingView<MenuBarPanel>?

    init(actions: MenuBarPanelActions, prepare: @escaping (AppConfigurationCandidate, @escaping (WindowTargetCaptureResult) -> Void) -> Void) {
        self.prepare = prepare
        super.init()
        clickSource.onForegroundChange = { [weak self] pid in
            guard let self, let originPID = self.originPID, pid != originPID else { return }
            // 与来源捕获共用真实前台变化；菜单代理的激活通知不能误关菜单。
            self.logFocus("foreground-changed")
            self.menu.cancelTracking()
        }
        // 配置异步加载期间保持隐藏，避免已关闭的图标在启动时短暂出现。
        statusItem.isVisible = false
        var actions = actions
        let performWindow = actions.performWindow
        actions.performWindow = { [weak self] action, targetID in
            self?.menu.cancelTracking()
            performWindow(action, targetID)
        }
        let performScene = actions.performScene
        actions.performScene = { [weak self] id in
            self?.menu.cancelTracking()
            performScene(id)
        }
        let undoScene = actions.undoScene
        actions.undoScene = { [weak self] token in
            self?.menu.cancelTracking()
            undoScene(token)
        }
        let openScenes = actions.openScenes
        actions.openScenes = { [weak self] in
            self?.menu.cancelTracking()
            openScenes()
        }
        let openSection = actions.openSection
        actions.openSection = { [weak self] section in
            self?.menu.cancelTracking()
            openSection(section)
        }
        let quit = actions.quit
        actions.quit = { [weak self] in
            self?.menu.cancelTracking()
            quit()
        }
        menu.delegate = self
        menu.autoenablesItems = false
        let hosting = NSHostingView(rootView: MenuBarPanel(state: state, actions: actions))
        hosting.frame.size = hosting.fittingSize
        self.hosting = hosting
        let item = NSMenuItem()
        item.view = hosting
        menu.addItem(item)
        // 原生菜单入口由系统进入菜单跟踪，不能再经普通按钮 action 自行弹窗。
        statusItem.menu = menu
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.setAccessibilityHelp(L10n.string(.App.menuBarOpenArcKitQuickPanel))
        }
        refreshPresentation(isVisible: false)
    }

    func refreshPresentation(isVisible: Bool) {
        if statusItem.isVisible != isVisible {
            // 隐藏同时结束菜单跟踪与目标捕获，只停止菜单入口自己的输入监听。
            if !isVisible { stop() }
            statusItem.isVisible = isVisible
        }
        if isVisible && state.settings.windowManagement.isEnabled { clickSource.startIfAuthorized() }
        else { clickSource.stop() }
        let issue = [state.windowHealth, state.mouseHealth].first(where: \.needsAttention)
        if let button = statusItem.button {
            button.image = issue == nil ? ArcBrandImage.menuBar : ArcIconImage.image(.triangleAlert)
            let status = issue?.title ?? L10n.string(.App.menuBarQuickPanel)
            button.toolTip = "Arc Kit：\(status)"
            button.setAccessibilityLabel("Arc Kit，\(status)")
        }
        switch state.settings.appearance {
        case .system: hosting?.appearance = nil
        case .light: hosting?.appearance = NSAppearance(named: .aqua)
        case .dark: hosting?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        hosting?.frame.size = hosting?.fittingSize ?? .zero
        // 结果保留到本次菜单结束；再次展开不把旧结果当作当前检测。
        if !state.statusCheck.isChecking { state.statusCheck = .idle }
        let requestID = state.windowTarget.begin()
        state.windowTargetName = nil
        originPID = nil
        let origin = clickSource.consumeMenuClick()
        logFocus("will-open", origin: origin)
        guard state.settings.windowManagement.isEnabled else {
            state.windowTarget.complete(.unavailable(L10n.string(.App.menuBarEnableWindowManagementFirst)), for: requestID)
            return
        }
        guard state.windowActionsAvailable else {
            let reason = state.windowHealth.detail.isEmpty ? state.windowHealth.title : state.windowHealth.detail
            state.windowTarget.complete(.unavailable(reason), for: requestID)
            return
        }
        guard let origin,
              let foreground = NSWorkspace.shared.frontmostApplication,
              foreground.processIdentifier == origin.application.processIdentifier,
              foreground.bundleIdentifier == origin.application.bundleIdentifier else {
            // 缺少前置输入证据或转发期间前台已变化时禁用布局，不猜选旧应用或当前应用。
            state.windowTarget.complete(.unavailable(L10n.string(.App.menuBarWindowCapturedClickSelectMissing)), for: requestID)
            return
        }
        state.windowTargetName = origin.application.displayName
        originPID = origin.application.processIdentifier
        prepare(origin.application) { [weak self] capture in
            guard let self, self.state.windowTarget.complete(capture, for: requestID) else { return }
            self.logFocus(capture.targetID == nil ? "target-unavailable" : "target-ready", origin: origin)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        logFocus("closed")
        state.windowTarget.reset()
        state.windowTargetName = nil
        originPID = nil
    }

    func stop() {
        menu.cancelTracking()
        menuDidClose(menu)
        clickSource.stop()
    }

    private func logFocus(_ phase: String, origin: MenuBarClickSource.Origin? = nil) {
        // 不写窗口标题和内容；来源时间可与原始输入采样直接对齐。
        ArcKitLog.append("window menu phase=\(phase) session=\(state.windowTarget.requestID?.uuidString ?? "none") uptime=\(ProcessInfo.processInfo.systemUptime) inputTime=\(origin?.timestamp ?? 0) origin=\(origin?.application.processIdentifier ?? 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) appActive=\(NSApp.isActive) target=\(state.windowTarget.targetID?.uuidString ?? "none")")
    }
}
