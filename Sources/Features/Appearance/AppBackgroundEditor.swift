import ArcKitPlatform
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppBackgroundEditor: View {
    @ObservedObject var model: AppBackgroundModel
    let openLibrary: () -> Void
    @State private var showsImport = false
    @State private var requestedStyle: AppBackgroundStyle?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    AppBackgroundPreview(model: model)
                    Picker(L10n.string(.AppBackground.backgroundBackgroundStyle), selection: styleSelection) {
                        ForEach(AppBackgroundStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                    if model.settings.style == .image || model.settings.style == .video, let name = model.settings.imageName {
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(name)
                    }
                }.padding(.vertical, 4)
                if model.settings.style == .image || model.settings.style == .video {
                HStack(spacing: 10) {
                    Button(model.settings.imageID == nil ? L10n.string(.AppBackground.backgroundChooseFile) : L10n.string(.AppBackground.backgroundReplaceFile)) { requestedStyle = nil; showsImport = true }
                    Button(L10n.string(.AppBackground.backgroundBrowseWallpapers), action: openLibrary)
                    Spacer(minLength: 0)
                    if model.settings.imageID != nil {
                        Menu {
                            Button(L10n.string(.AppBackground.backgroundClearBackgroundFile), role: .destructive, action: model.clearImage)
                        } label: { ArcIcon(.menu, size: 14) }
                            .menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel(L10n.string(.AppBackground.backgroundBackgroundFileActions))
                    }
                }
                }
                if reduceTransparency {
                    Text(L10n.string(.AppBackground.backgroundReduceTransparencyEnabledMacosSo))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.imageError {
                    Label { Text(error).font(.caption) } icon: { ArcIcon(.triangleAlert, size: 14) }
                        .foregroundStyle(.orange)
                }
            } header: { Text(L10n.string(.AppBackground.backgroundAppBackground)) }
              footer: { Text(L10n.string(.AppBackground.backgroundUsedArcKitWindowsImages)) }

            if model.settings.style == .aura { AuraThemeEditor(model: model) }
            if model.settings.style == .image || model.settings.style == .video {
                Section {
                    adjustment(L10n.string(.AppBackground.backgroundOpacity), value: value(\.opacity), range: 0.05...1, step: 0.05,
                               text: "\(Int((model.settings.opacity * 100).rounded()))%")
                    if model.settings.style == .image || model.settings.style == .video {
                        adjustment(L10n.string(.AppBackground.backgroundBlur), value: value(\.blur), range: 0...60, step: 1,
                                   text: "\(Int(model.settings.blur)) pt")
                    }
                    adjustment(L10n.string(.AppBackground.backgroundInterfaceOverlay), value: value(\.dimming), range: 0...0.85, step: 0.05,
                               text: "\(Int((model.settings.dimming * 100).rounded()))%")
                } header: {
                    HStack {
                        Text(L10n.string(.AppBackground.backgroundAppearanceAdjustments))
                        Spacer()
                        if model.settings.style == .image || model.settings.style == .video {
                            Button(L10n.string(.AppBackground.backgroundRestoreClarity)) { model.update { $0.restoreMediaClarity() } }
                                .buttonStyle(.link).controlSize(.small)
                                .help(L10n.string(.AppBackground.backgroundRestoreHint))
                        }
                    }
                }
                  footer: { Text(L10n.string(.AppBackground.backgroundVideosLoopSilentlyVideosEffectsPause)) }
            }
            Section {
                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(L10n.string(.AppBackground.backgroundLoadingBackground)).font(.caption)
                    } else {
                        switch model.persistenceState {
                        case .pending: Text(L10n.string(.AppBackground.backgroundSaving)).font(.caption).foregroundStyle(.secondary)
                        case .saved: Text(L10n.string(.AppBackground.backgroundChangesSaveAutomatically)).font(.caption).foregroundStyle(.secondary)
                        case .failed: Text(model.hasUnsavedChanges ? L10n.string(.AppBackground.backgroundUnsavedChanges) : L10n.string(.AppBackground.backgroundBackgroundOperationFailed)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(L10n.string(.AppBackground.backgroundResetBackground), action: model.reset)
                }
            }
        }
        .disabled(!model.isLoaded || model.isBusy)
        .fileImporter(isPresented: $showsImport, allowedContentTypes: requestedStyle == .image ? [.image] : requestedStyle == .video ? [.movie] : [.image, .movie]) { result in
            switch result {
            case let .success(url):
                if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) { model.useVideo(url) }
                else { model.useImage(url) }
            case let .failure(error): model.showImportError(error)
            }
        }
    }

    private var styleSelection: Binding<AppBackgroundStyle> {
        Binding(get: { model.settings.style }, set: { style in
            // 分段控件选到尚无素材的样式时先选文件，取消不会写入无效背景设置。
            if (style == .image && model.settings.imageID == nil) || (style == .video && model.settings.videoFilename == nil) {
                requestedStyle = style; showsImport = true
            } else { model.update { $0.style = style } }
        })
    }

    private func value<Value>(_ path: WritableKeyPath<AppBackgroundSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }

    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, text: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 76, alignment: .leading)
            Slider(value: value, in: range, step: step) { Text(title) }
                .labelsHidden()
            Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }
}

/// 图片入口在多个页面共享同一回执；反馈不插入布局，失败可以重试或重新加载。
struct AppBackgroundFeedback: View {
    @ObservedObject var model: AppBackgroundModel
    @State private var presented: SettingsPersistenceState?
    @State private var event: SettingsPersistenceState?
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let presented {
                HStack(alignment: .top, spacing: 8) {
                    if case .pending = presented {
                        ProgressView().controlSize(.small)
                    } else { ArcIcon(isError ? .triangleAlert : .checkCircle, size: 14) }
                    Text(message).font(.caption).lineLimit(4).help(message)
                    if case .failed = presented {
                        Button(L10n.string(.Common.retry), action: model.retrySave)
                        Button(L10n.string(.Common.reload), action: model.discardChanges)
                    }
                    Button { self.presented = nil } label: { ArcIcon(.circleX, size: 14) }
                        .accessibilityLabel(L10n.string(.AppBackground.backgroundDismissBackgroundMessage))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isError ? Color.orange : Color.secondary)
                .padding(12).frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
        }
        .onAppear { if case .failed = model.persistenceState { event = model.persistenceState } }
        .onChange(of: model.persistenceState) { event = $0 }
        .task(id: event) {
            do {
                switch event {
                case .pending:
                    presented = nil
                    try await Task.sleep(for: .milliseconds(600))
                    presented = .pending
                case .saved(nil), nil:
                    presented = nil
                case .saved:
                    presented = event
                    try await Task.sleep(for: .seconds(2))
                    presented = nil
                case .failed:
                    presented = event
                }
            } catch { }
        }
    }
    private var isError: Bool { if case .failed = presented { true } else { false } }
    private var message: String {
        switch presented {
        case .pending: L10n.string(.AppBackground.backgroundSavingAppBackground)
        case let .failed(error): L10n.string(.AppBackground.backgroundAccessibilityLabel(String(describing: error)))
        default: L10n.string(.AppBackground.backgroundAppBackgroundSaved)
        }
    }
}
