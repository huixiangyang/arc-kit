import ArcKitPlatform
import ArcKitWindow
import SwiftUI

/// 场景配置仍属于全局设置事务；只有保存到 Host 的配置才能执行。
struct WindowScenesEditor: View {
    @ObservedObject var model: SettingsEditor<WindowManagementSettings>
    @ObservedObject var windowService: WindowManagementService
    @State private var editor: WindowSceneEditorContext?
    @State private var pendingDeletion: WindowScene?

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string(.WindowSettings.scenesTitle)).font(.headline)
                    Text(L10n.string(.WindowSettings.scenesIntro))
                        .font(.caption).foregroundStyle(ArcPalette.secondaryText)
                }
                Spacer()
                ArcToolbarButton(title: L10n.string(.WindowSettings.scenesCapture), symbol: .plus) {
                    editor = .init(scene: nil, selectsCurrentWindows: true)
                }
                .disabled(!model.settings.isEnabled || !windowService.accessibilityOperational || model.settings.scenes.count >= WindowScene.maximumSceneCount)
            }
            if model.settings.scenes.count >= WindowScene.maximumSceneCount {
                Text(L10n.string(.WindowSettings.scenesLimit(WindowScene.maximumSceneCount))).font(.caption).foregroundStyle(ArcPalette.orange)
            }
            if !windowService.accessibilityOperational {
                Text(L10n.string(.WindowSettings.scenesNeedsPermission)).font(.caption).foregroundStyle(ArcPalette.orange)
            }
            if model.hasUncommittedChanges {
                Text(L10n.string(.WindowSettings.scenesSaveBeforeApply)).font(.caption).foregroundStyle(ArcPalette.orange)
            }
            if model.settings.scenes.isEmpty {
                HStack(spacing: 12) {
                    ArcIcon(.layoutDashboard, size: 30).foregroundStyle(ArcPalette.mutedText)
                    Text(L10n.string(.WindowSettings.scenesEmpty)).font(.subheadline).foregroundStyle(ArcPalette.secondaryText)
                }
                .padding(.vertical, 20)
            }
            ForEach(model.settings.scenes) { scene in
                sceneRow(scene)
            }
        }
        if let message = windowService.lastSceneError {
            Section {
                Text(message).font(.caption).foregroundStyle(ArcPalette.orange)
            }
        }
        if let report = windowService.lastSceneResult {
            WindowSceneResultSection(report: report, scene: model.settings.scenes.first(where: { $0.id == report.sceneID }), windowService: windowService) { sceneID in
                guard let scene = model.settings.scenes.first(where: { $0.id == sceneID }) else { return }
                editor = .init(scene: scene, selectsCurrentWindows: false)
            }
        }
        Section {
            Text(L10n.string(.WindowSettings.scenesScope))
                .font(.caption).foregroundStyle(ArcPalette.secondaryText)
        }
        .sheet(item: $editor) { context in
            WindowSceneEditorSheet(model: model, windowService: windowService, context: context)
        }
        .confirmationDialog(L10n.string(.WindowSettings.scenesDeleteTitle), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.string(.Common.remove), role: .destructive) {
                guard let scene = pendingDeletion else { return }
                model.update(actionName: L10n.string(.WindowSettings.scenesDeleteTitle)) {
                    $0.scenes.removeAll { $0.id == scene.id }
                }
                pendingDeletion = nil
            }
            Button(L10n.string(.Common.cancel), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.string(.WindowSettings.scenesDeleteHint))
        }
    }

    private func sceneRow(_ scene: WindowScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                WindowSceneLayoutPreview(displays: scene.displays, entries: scene.entries)
                    .frame(width: 156, height: 76)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name).font(.headline)
                    Text(L10n.string(.WindowSettings.scenesCounts(scene.entries.count, scene.displays.count)))
                        .font(.caption).foregroundStyle(ArcPalette.secondaryText)
                    if let shortcut = scene.shortcut, shortcut.isEnabled {
                        Text(shortcut.displayShortcut).font(.caption.monospaced())
                    }
                }
                Spacer(minLength: 8)
                Button(L10n.string(.WindowSettings.scenesApply)) { windowService.applyScene(id: scene.id) }
                    .buttonStyle(.bordered)
                    .disabled(model.hasUncommittedChanges || windowService.isApplyingScene || !windowService.accessibilityOperational || !model.settings.isEnabled)
                Menu {
                    Button(L10n.string(.WindowSettings.scenesEdit)) { editor = .init(scene: scene, selectsCurrentWindows: false) }
                    Button(L10n.string(.WindowSettings.scenesUpdateLayout)) { editor = .init(scene: scene, selectsCurrentWindows: true) }
                    Button(L10n.string(.WindowSettings.scenesSaveAs)) {
                        var duplicate = scene
                        duplicate.id = UUID()
                        duplicate.name = L10n.string(.WindowSettings.scenesCopyName(scene.name))
                        duplicate.shortcut = nil
                        editor = .init(scene: duplicate, selectsCurrentWindows: false)
                    }
                    .disabled(model.settings.scenes.count >= WindowScene.maximumSceneCount)
                    Divider()
                    Button(L10n.string(.Common.remove), role: .destructive) { pendingDeletion = scene }
                } label: {
                    ArcIcon(.menu, size: 16)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L10n.string(.WindowSettings.scenesActions))
            }
            if let failure = windowService.sceneHotKeyFailures[scene.id] {
                Text(failure).font(.caption).foregroundStyle(ArcPalette.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

struct WindowSceneEditorContext: Identifiable {
    let id = UUID()
    let scene: WindowScene?
    let selectsCurrentWindows: Bool
}

/// 缩略图仅绘制几何信息，不读取窗口内容或申请录屏权限。
struct WindowSceneLayoutPreview: View {
    let displays: [WindowSceneDisplay]
    let entries: [WindowSceneEntry]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(displays) { display in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 5).fill(ArcPalette.secondaryText.opacity(0.06))
                        RoundedRectangle(cornerRadius: 5).strokeBorder(ArcPalette.secondaryText.opacity(0.25))
                        ForEach(entries.filter { $0.displayID == display.id }) { entry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor.opacity(0.6)))
                                .frame(width: max(2, geometry.size.width * entry.normalizedFrame.width), height: max(2, geometry.size.height * entry.normalizedFrame.height))
                                .offset(x: geometry.size.width * entry.normalizedFrame.x, y: geometry.size.height * entry.normalizedFrame.y)
                        }
                    }
                    .clipped()
                }
                .aspectRatio(max(0.2, display.visibleFrame.width / max(1, display.visibleFrame.height)), contentMode: .fit)
            }
        }
    }
}
