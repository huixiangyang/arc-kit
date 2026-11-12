import ArcKitPlatform
import SwiftUI

struct MenuBarSection: View {
    @ObservedObject var model: SettingsEditor<MenuBarSettings>
    @ObservedObject var service: MenuBarManagementService
    @ObservedObject private var inventory: MenuBarShelfModel
    @ObservedObject private var arrangement: MenuBarArrangementModel
    @StateObject private var workflow: MenuBarWorkflow
    @State private var showsSettings = false
    @State private var ownerID: UUID
    private enum Page { case arrange, search }
    @State private var page: Page = .arrange
    private let usesSampleData: Bool

    init(model: SettingsEditor<MenuBarSettings>, service: MenuBarManagementService,
         workflow: MenuBarWorkflow? = nil, ownerID: UUID = UUID(), usesSampleData: Bool = false) {
        self.model = model; self.service = service
        inventory = service.managementModel
        arrangement = service.arrangementModel
        self.usesSampleData = usesSampleData || service.isPreview
        _ownerID = State(initialValue: ownerID)
        _workflow = StateObject(wrappedValue: workflow ?? MenuBarWorkflow(editor: model, service: service))
    }

    private var isEnabled: Bool { model.committedSettings?.isEnabled == true }
    private var isCollapsed: Bool { workflow.presentation == .collapsed }
    private var isChanging: Bool { workflow.isWorking || service.pendingPresentation != nil }
    private var needsCollectionSelection: Bool {
        service.partitionMode == .systemVisibility && model.committedSettings?.collectedApplications.isEmpty == true
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string(.MenuBar.pageTitle)).font(.system(size: 22, weight: .semibold))
                    if usesSampleData {
                        Text(L10n.string(.MenuBar.managementPreview)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showsSettings = true } label: {
                        HStack(spacing: 6) { ArcIcon(.settings, size: 14); Text(L10n.string(.MenuBar.flowSettings)) }
                    }.buttonStyle(.borderless).disabled(workflow.isWorking)
                }
                collection(compact: true, inline: geometry.size.width >= 600)
                Picker(L10n.string(.MenuBar.pageTitle), selection: $page) {
                    Text(L10n.string(.MenuBar.arrangeTab)).tag(Page.arrange)
                    Text(L10n.string(.MenuBar.arrangeSearchTab)).tag(Page.search)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).disabled(arrangement.isApplying)
                if page == .arrange {
                    MenuBarArrangementView(model: service.arrangementModel,
                        refresh: { service.arrangementModel.refresh(collectionEnabled: isEnabled, discard: true) },
                        apply: service.applyArrangement, openPermission: service.openAccessibilitySettings)
                } else {
                    MenuBarManagementList(inventory: inventory, canInteract: service.canSearchAllIcons,
                        refresh: { service.refreshManagement(owner: ownerID) }, openPermission: service.openAccessibilitySettings,
                        activate: { service.activateManagementItem($0, owner: ownerID) }, usesSampleData: usesSampleData)
                }
            }.padding(24)
        }.appBackgroundSurface()
            .sheet(isPresented: $showsSettings) { MenuBarPreferencesSheet(model: model, service: service) }
            .onAppear { startPage() }
            .onChange(of: page) { _ in startPage() }
            .onChange(of: isEnabled) { _ in if page == .arrange { service.arrangementModel.refresh(collectionEnabled: isEnabled) } }
            .onDisappear { service.endManagement(owner: ownerID); service.arrangementModel.leave(); workflow.leave() }
    }

    private func startPage() {
        if page == .search { service.arrangementModel.leave(); service.beginManagement(owner: ownerID) }
        else {
            service.endManagement(owner: ownerID)
            if !usesSampleData { service.arrangementModel.refresh(collectionEnabled: isEnabled) }
        }
    }

    #if DEBUG
    /// 原有清单交互回归继续从查找页开始；编排页使用独立的离屏入口。
    func searchPreview() -> Self {
        var copy = self
        copy._page = State(initialValue: .search)
        return copy
    }
    #endif

    private func collection(compact: Bool, inline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(spacing: 12) {
                Text(L10n.string(.MenuBar.managementCollection)).font(.system(size: 14, weight: .semibold))
                if compact { collectionStatus }
                Spacer(minLength: 8)
                if inline && isEnabled { collectionActions }
                Toggle(L10n.string(.MenuBar.flowEnable), isOn: Binding(get: { isEnabled }, set: { enabled in
                    Task { await workflow.setEnabled(enabled) }
                })).labelsHidden().toggleStyle(.switch).tint(ArcPalette.orange).controlSize(.small).fixedSize()
                    .disabled(workflow.isWorking || arrangement.isApplying || model.committedSettings == nil)
            }
            if !compact { collectionStatus }
            if isEnabled {
                if !inline {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { collectionActions }
                        VStack(alignment: .leading, spacing: 10) { collectionActions }
                    }
                }
                if !isCollapsed && page == .search {
                    Text(L10n.string(.MenuBar.flowDragInstruction)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsCollectionSelection {
                    Text(L10n.string(.MenuBar.collectionSetupHint)).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = workflow.error {
                notice(error, icon: .triangleAlert)
                Button(L10n.string(.MenuBar.flowRetry)) { Task { await workflow.retry() } }.disabled(workflow.isWorking)
            } else if let error = service.message, isEnabled, !needsCollectionSelection {
                notice(error, icon: .triangleAlert)
            }
            if let status = service.environmentState.status {
                notice(status, icon: .circleInfo)
            }
            if isChanging { ProgressView().controlSize(.small) }
        }.padding(compact ? 14 : 18).frame(maxWidth: .infinity, alignment: .leading)
            .background(ArcPalette.panel.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ArcPalette.panelBorder.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder private var collectionActions: some View {
        if needsCollectionSelection {
            Button(L10n.string(.MenuBar.collectionChooseApplications)) {
                arrangement.query = ""
                if page == .arrange { arrangement.refresh(collectionEnabled: isEnabled) }
                else { page = .arrange }
            }.buttonStyle(.borderedProminent).tint(ArcPalette.orange)
                .disabled(isChanging || arrangement.isApplying)
        } else {
            Button(action: workflow.toggle) {
                HStack(spacing: 5) {
                    ArcIcon(MenuBarControlAppearance.toggleIcon(for: workflow.presentation), size: 14)
                    Text(MenuBarControlAppearance.actionLabel(for: workflow.presentation))
                }
            }.buttonStyle(.bordered)
                .help(MenuBarControlAppearance.actionLabel(for: workflow.presentation))
                .accessibilityLabel(MenuBarControlAppearance.actionLabel(for: workflow.presentation))
                .disabled(isChanging || arrangement.isApplying || model.hasUncommittedChanges || service.environmentState != .ready)
        }
        Button(L10n.string(.MenuBar.actionShowAll), action: workflow.showAll)
            .buttonStyle(.borderless).disabled(workflow.isWorking)
    }

    private var collectionStatus: some View {
        Text(L10n.string(isEnabled ? (needsCollectionSelection ? .MenuBar.collectionNeedsSelection : (isCollapsed ? .MenuBar.flowHidden : .MenuBar.flowVisible)) : .MenuBar.managementCollectionOff))
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func notice(_ text: String, icon: ArcIconName) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ArcIcon(icon, size: 14).foregroundStyle(ArcPalette.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
