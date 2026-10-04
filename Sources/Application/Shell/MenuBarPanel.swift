import ArcKitPlatform
import ArcKitWindow
import SwiftUI

/// 只投影已经存在的配置与运行证据，不持有第二份可写设置。
@MainActor
final class MenuBarPanelState: ObservableObject {
    @Published var settings = AppSettings.defaults
    @Published var windowHealth = FeatureHealth(state: .unknown, title: L10n.string(.App.menuBarUnchecked), detail: "")
    @Published var mouseHealth = FeatureHealth(state: .unknown, title: L10n.string(.App.menuBarUnchecked), detail: "")
    @Published var windowActionsAvailable = false
    @Published var sceneActionsAvailable = false
    @Published var isApplyingScene = false
    @Published var lastSceneResult: WindowSceneExecutionReport?
    @Published var sceneError: String?
    @Published var windowTarget = WindowTargetSession()
    @Published var windowTargetName: String?
    var canPerformWindowActions: Bool { windowActionsAvailable && windowTarget.targetID != nil }
    @Published var screenCount = 0
    @Published var saveFailure: String?
    @Published var statusCheck = MenuBarStatusCheck.idle
}

enum MenuBarStatusCheck {
    case idle, checking
    case completed(detail: String, needsAttention: Bool, at: Date)
    case failed(message: String, at: Date)

    var isChecking: Bool { if case .checking = self { true } else { false } }
    var title: String {
        switch self {
        case .idle: L10n.string(.App.menuBarCheckStatus)
        case .checking: L10n.string(.App.menuBarChecking)
        case .completed(_, let needsAttention, _): needsAttention ? L10n.string(.App.menuBarNeedsAttention) : L10n.string(.App.menuBarCheckedStatus)
        case .failed: L10n.string(.App.menuBarCheckFailed)
        }
    }
    var icon: ArcIconName {
        switch self {
        case .idle, .checking: .refreshCw
        case .completed(_, let needsAttention, _): needsAttention ? .triangleAlert : .checkCircle
        case .failed: .circleX
        }
    }
    var color: Color {
        switch self {
        case .idle, .checking: .primary
        case .completed(_, let needsAttention, _): needsAttention ? ArcPalette.orange : ArcPalette.green
        case .failed: ArcPalette.red
        }
    }
    var help: String {
        let purpose = L10n.string(.App.menuBarReadinessHint)
        switch self {
        case .idle: return L10n.string(.App.menuBarCheckScope(String(describing: purpose)))
        case .checking: return L10n.string(.App.menuBarWaitingBackgroundResponse(String(describing: purpose)))
        case let .completed(detail, needsAttention, at):
            let next = needsAttention ? L10n.string(.App.menuBarSeeHomeNextStepsClick) : L10n.string(.App.menuBarClickCheckAgain)
            return L10n.string(.App.menuBarChecked(String(describing: L10n.time(at)), String(describing: detail), String(describing: next)))
        case let .failed(message, at):
            return L10n.string(.App.menuBarCheckSeeHomeNextStepsFailed(String(describing: L10n.time(at)), String(describing: message)))
        }
    }
}

struct MenuBarPanelActions {
    var performWindow: @MainActor (WindowLayoutAction, UUID) -> Void
    var performScene: @MainActor (UUID) -> Void
    var undoScene: @MainActor (UUID) -> Void
    var openScenes: @MainActor () -> Void
    var setWindowEnabled: @MainActor (Bool) -> Void
    var setMouseEnabled: @MainActor (Bool) -> Void
    var setFinderEnabled: @MainActor (Bool) -> Void
    var openSection: @MainActor (MainWindowSection) -> Void
    var retrySave: @MainActor () -> Void
    var checkState: @MainActor () -> Void
    var quit: @MainActor () -> Void
}

/// 原生菜单承载内容；保持普通字号和固定分组。
struct MenuBarPanel: View {
    @ObservedObject var state: MenuBarPanelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let actions: MenuBarPanelActions

    var body: some View {
        VStack(spacing: 10) {
            header
            windowControls
            Divider()
            sceneControls
            Divider()
            featureControls
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(width: L10n.language.resolved() == .english ? 320 : 272)
        .environment(\.locale, state.settings.language.locale)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ArcBrandMark(size: 18)
                .accessibilityLabel("Arc Kit")
            Text(targetStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .help(state.windowTarget.failureMessage ?? state.windowTargetName ?? L10n.string(.App.menuBarTargetWindow))
                .accessibilityLabel(state.windowTarget.failureMessage ?? targetStatus)
            Spacer()
            // 操作和结果共用固定宽度；名称始终可见，不靠悬停猜用途，也不挤动布局。
            if let failure = state.saveFailure {
                Button(action: actions.retrySave) {
                    HStack(spacing: 4) {
                        ArcIcon(.triangleAlert, size: 13)
                        Text(L10n.string(.App.menuBarRetrySave)).font(.system(size: 11))
                    }
                    .frame(width: L10n.language.resolved() == .english ? 96 : 76, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ArcPalette.red)
                .help(L10n.string(.App.menuBarSaveClickRetryFailed(String(describing: failure))))
                .accessibilityLabel(L10n.string(.App.menuBarSaveRetrySaveFailed))
            } else {
                statusCheckButton
            }
            iconButton(L10n.string(.Common.settings), icon: .settings) { actions.openSection(.preferences) }
            iconButton(L10n.string(.App.menuQuitArcKit), icon: .power, action: actions.quit)
        }
        .frame(height: 24)
    }

    private var statusCheckButton: some View {
        Button(action: actions.checkState) {
            HStack(spacing: 4) {
                if state.statusCheck.isChecking && !reduceMotion {
                    MenuBarCheckSpinner()
                } else {
                    ArcIcon(state.statusCheck.icon, size: 13)
                }
                Text(state.statusCheck.title).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(state.statusCheck.color)
            .frame(width: L10n.language.resolved() == .english ? 96 : 76, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.statusCheck.isChecking)
        .help(state.statusCheck.help)
        .accessibilityLabel(state.statusCheck.title)
        .accessibilityValue(state.statusCheck.help)
    }

    private var targetStatus: String {
        switch state.windowTarget.phase {
        case .idle: ""
        case .capturing: L10n.string(.App.menuBarLoading)
        case .resolved(_, .ready): state.windowTargetName ?? L10n.string(.App.menuBarWindowReady)
        case .resolved(_, .unavailable): L10n.string(.App.menuBarWindowUnavailable)
        }
    }

    private var targetFailure: String? {
        guard case let .resolved(_, .unavailable(message)) = state.windowTarget.phase else { return nil }
        return message
    }

    private var windowControls: some View {
        VStack(spacing: 6) {
            layoutRow([.fill, .stageManager, .center, .fullScreen])
            layoutRow([.leftHalf, .rightHalf, .topHalf, .bottomHalf])
            layoutRow([.topLeft, .topRight, .bottomLeft, .bottomRight])
            layoutRow([.leftThird, .centerThird, .rightThird])
            layoutRow([.leftTwoThirds, .rightTwoThirds])
        }
        // 失败原因直接显示在布局区，保持菜单尺寸稳定，不再把所有失败都说成没有窗口。
        .opacity(targetFailure == nil ? 1 : 0)
        .accessibilityHidden(targetFailure != nil)
        .overlay {
            if let targetFailure {
                VStack(spacing: 8) {
                    ArcIcon(.triangleAlert, size: 18).foregroundStyle(.secondary)
                    Text(targetFailure)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func layoutRow(_ row: [WindowLayoutAction]) -> some View {
        HStack(spacing: 6) {
            ForEach(row) { action in
                Button {
                    guard let targetID = state.windowTarget.targetID else { return }
                    actions.performWindow(action, targetID)
                } label: {
                    VStack(spacing: 3) {
                        ArcIcon(action.menuBarIcon, size: 15)
                        Text(action.menuBarTitle)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    // 英文布局名称允许两行，保持字号可读且不截断 Stage Manager。
                    .frame(height: L10n.language.resolved() == .english ? 50 : 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuBarTileStyle())
                .disabled(!state.canPerformWindowActions || !WindowActionAvailability.isAvailable(action, screenCount: state.screenCount))
                .help(actionHelp(action))
                .accessibilityLabel(action.displayName)
            }
        }
    }

    private func actionHelp(_ action: WindowLayoutAction) -> String {
        if let unavailable = WindowActionAvailability.unavailableReason(action, screenCount: state.screenCount) { return unavailable }
        if !state.settings.windowManagement.isEnabled { return L10n.string(.App.menuBarEnableWindowManagementFirst) }
        if !state.windowActionsAvailable { return state.windowHealth.detail }
        if let failure = state.windowTarget.failureMessage { return failure }
        let detail = action == .stageManager ? L10n.string(.App.menuBarStageManagerHint) : action.displayName
        if let binding = state.settings.windowManagement.binding(for: action), binding.isEnabled {
            return "\(detail) · \(binding.displayShortcut)"
        }
        return detail
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string(.App.scenesTitle)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(L10n.string(.App.scenesManage), action: actions.openScenes)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if state.settings.windowManagement.scenes.isEmpty {
                Button(L10n.string(.App.scenesCreate), action: actions.openScenes)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.settings.windowManagement.scenes) { scene in
                            Button { actions.performScene(scene.id) } label: {
                                HStack(spacing: 7) {
                                    ArcIcon(.panelsTopLeft, size: 13)
                                    Text(scene.name).lineLimit(1)
                                    Spacer()
                                    ArcIcon(.cornerDownLeft, size: 11).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 5).frame(height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(MenuBarTileStyle())
                            // 场景有自己的固定目标，不需要菜单点击时的单窗口捕获令牌。
                            .disabled(!state.sceneActionsAvailable || state.isApplyingScene)
                            .help(L10n.string(.App.scenesApplyHint))
                        }
                    }
                }
                .frame(height: CGFloat(min(state.settings.windowManagement.scenes.count, 4)) * 28)
            }
            if state.isApplyingScene {
                Text(L10n.string(.App.scenesApplying)).foregroundStyle(.secondary)
            } else if let error = state.sceneError {
                Text(error).font(.caption).foregroundStyle(ArcPalette.orange).lineLimit(2).help(error)
            } else if let result = state.lastSceneResult {
                Button(action: actions.openScenes) {
                    Text(result.summary).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).help(L10n.string(.App.scenesResultHint))
            }
            if let token = state.lastSceneResult?.undoToken {
                Button { actions.undoScene(token) } label: {
                    Label { Text(L10n.string(.App.scenesUndo)) } icon: { ArcIcon(.undo2, size: 12) }
                }
                .buttonStyle(.plain).disabled(!state.sceneActionsAvailable || state.isApplyingScene)
            }
        }
    }

    private var featureControls: some View {
        VStack(spacing: 0) {
            // 布局操作集中在上方，三个功能的总开关统一放在下方。
            featureRow(L10n.string(.App.searchWindowManagement), icon: .appWindowMac, section: .window,
                       enabled: state.settings.windowManagement.isEnabled, set: actions.setWindowEnabled)
            Divider()
            featureRow(L10n.string(.App.searchMouseEnhancement), icon: .mouse, section: .mouse,
                       enabled: state.settings.mouseEnhancement.isEnabled, set: actions.setMouseEnabled)
            Divider()
            featureRow(L10n.string(.App.menuBarFinderMenu), icon: .folder, section: .finder,
                       enabled: state.settings.finder.menuConfiguration.isEnabled, set: actions.setFinderEnabled)
            Divider()
            navigationRow(L10n.string(.Common.wallpaper), icon: .image, section: .wallpaper)
        }
    }

    private func featureRow(_ title: String, icon: ArcIconName, section: MainWindowSection,
                            enabled: Bool, set: @escaping @MainActor (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Button { actions.openSection(section) } label: {
                HStack(spacing: 8) {
                    ArcIcon(icon, size: 15).foregroundStyle(.secondary)
                    Text(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(.App.menuBarOpenSettings(String(describing: title))))
            Toggle(title, isOn: Binding(get: { enabled }, set: { set($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(height: 30)
    }

    private func navigationRow(_ title: String, icon: ArcIconName, section: MainWindowSection) -> some View {
        Button { actions.openSection(section) } label: {
            HStack(spacing: 8) {
                ArcIcon(icon, size: 15).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                ArcIcon(.chevronRight, size: 12).foregroundStyle(.tertiary)
            }
            .frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ title: String, icon: ArcIconName, action: @escaping () -> Void) -> some View {
        Button(action: action) { ArcIcon(icon, size: 13).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

private struct MenuBarCheckSpinner: View {
    @State private var spinning = false

    var body: some View {
        ArcIcon(.refreshCw, size: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct MenuBarTileStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.08 : 0.035)))
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.055)) }
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}
