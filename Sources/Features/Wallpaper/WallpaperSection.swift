import ArcKitPlatform
import SwiftUI

enum WallpaperWorkspaceTab: String, CaseIterable, Identifiable {
    case library, online, motion, playback
    var id: Self { self }
    // 标签使用独立短文案，避免英文在最小窗口宽度下挤出分段控件。
    var title: String {
        switch self {
        case .library: L10n.string(.Wallpaper.tabsLibrary)
        case .online: L10n.string(.Wallpaper.tabsOnline)
        case .motion: L10n.string(.Wallpaper.tabsLive)
        case .playback: L10n.string(.Wallpaper.tabsPlayback)
        }
    }
}

struct WallpaperSection<BackgroundFeedback: View>: View {
    @ObservedObject var model: WallpaperModel
    let backgroundAction: WallpaperBackgroundAction
    let backgroundFeedback: BackgroundFeedback
    @Binding var selectedTab: WallpaperWorkspaceTab
    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string(.Wallpaper.pageWallpaperPage), selection: $selectedTab) {
                ForEach(WallpaperWorkspaceTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            switch selectedTab {
            case .library: WallpaperLibraryView(model: model, backgroundAction: backgroundAction) { selectedTab = .online }
            case .online: WallpaperOnlineView(model: model, background: backgroundAction)
            case .motion: MotionWallpaperView(model: model, background: backgroundAction)
            case .playback: WallpaperPlaybackView(model: model)
            }
        }
        .scrollIndicators(.never)
        .overlay(alignment: .bottomTrailing) {
            // 背景与壁纸可能同时保存，共用竖向回执区域，避免两层提示互相覆盖。
            VStack(alignment: .trailing, spacing: 8) {
                backgroundFeedback
                operationFeedback
            }.padding(16)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, model.isLoaded, urls.allSatisfy(\.isFileURL) else { return false }
            model.importFiles(urls); return true
        }
    }

    @ViewBuilder
    private var operationFeedback: some View {
        // 导入与保存反馈悬浮展示，避免短暂保存挤动图库或表单。
        if model.isBusy || model.feedback != nil {
            HStack(alignment: .top, spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.operationProgress ?? L10n.string(.Wallpaper.pageProcessing)).font(.caption)
                    Spacer()
                    if model.canCancelOperation { Button(L10n.string(.Common.cancel), action: model.cancelOperation).buttonStyle(.link) }
                } else if let feedback = model.feedback {
                    ArcIcon(feedback.kind == .failure ? .triangleAlert : (feedback.kind == .success ? .checkCircle : .circleInfo), size: 14)
                    Text(feedback.message).font(.caption).textSelection(.enabled).lineLimit(6).help(feedback.message)
                    Spacer(minLength: 4)
                    Button(L10n.string(.Common.close), action: model.clearFeedback).buttonStyle(.link)
                }
            }
            .foregroundStyle(model.hasError ? Color.orange : Color.secondary)
            .padding(12).frame(maxWidth: 380, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }

}
