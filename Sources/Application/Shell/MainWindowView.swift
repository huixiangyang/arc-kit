import ArcKitPlatform
import AppKit
import SwiftUI

/// 窗口壳层只组织侧栏、工具栏与内容，不持有各功能的客户端或数据服务。
struct MainWindowView<Workspace: View>: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var backgroundModel: AppBackgroundModel
    @ObservedObject var navigation: MainWindowNavigationModel
    let workspace: Workspace
    let prepareQuickFind: () -> Void
    let executeQuickCommand: (ArcKitQuickCommand) -> Void
    @State private var showsQuickFind = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { canvas in
            // 原生命名坐标从窗口顶部起算，但布局高度扣除了标题栏安全区；背景需补回这部分。
            let canvasFrame = CGRect(
                origin: canvas.frame(in: .named("ArcKitAppBackground")).origin,
                size: CGSize(width: canvas.size.width, height: canvas.size.height + canvas.safeAreaInsets.top)
            )
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
                    .background { AppBackgroundSlice(model: backgroundModel, canvasFrame: canvasFrame) }
            } detail: {
                workspace
                // 切页重建原生表单以回到顶部；资源 sheet 不改变父表单身份。
                .id(navigation.selection.rawValue)
                .frame(minWidth: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { AppBackgroundSlice(model: backgroundModel, canvasFrame: canvasFrame) }
                .overlay(alignment: .bottomTrailing) {
                    if navigation.selection != .wallpaper {
                        AppBackgroundFeedback(model: backgroundModel).padding(16)
                    }
                }
                .toolbar {
                    ToolbarItem {
                        // 回执占用标题栏，不覆盖内容；保留在页面身份外，切页不重启计时。
                        SettingsSaveToast(model: model)
                    }
                    ToolbarItem {
                        Button {
                            prepareQuickFind()
                            navigation.requestQuickFind()
                        } label: {
                            Label { Text(L10n.string(.App.windowQuickFind)) } icon: { ArcIcon(.search, size: 15) }
                        }
                        .help(L10n.string(.App.windowQuickFindK))
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .appBackgroundWindowChrome()
        }
        .modifier(AppBackgroundRuntime(model: backgroundModel))
        .coordinateSpace(name: "ArcKitAppBackground")
        .environment(\.appBackgroundVisible, backgroundModel.settings.style != .system && (!reduceTransparency || backgroundModel.settings.style == .aura))
        .environment(\.appBackgroundReduceMotion, shouldReduceMotion)
        .environment(\.appBackgroundWindowVisible, backgroundModel.isWindowVisible)
        // 外置鼠标会让 macOS 忽略 hidden；never 才能强制隐藏，滚动能力仍保留。
        .scrollIndicators(.never)
        .disabled(model.isOperationRunning)
        .frame(minWidth: ArcMetrics.mainWindowMinWidth)
        .toggleStyle(.switch)
        .applyAppearance(model.settings.appearance)
        .transaction { transaction in
            if shouldReduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .environment(\.locale, (model.committedSettings?.language ?? .system).locale)
        .onAppear {
            if navigation.quickFindRequestID > 0 {
                showsQuickFind = true
            }
        }
        .onChange(of: navigation.quickFindRequestID) { _ in
            showsQuickFind = true
        }
        .sheet(isPresented: $showsQuickFind) {
            ArcKitQuickFind(scenes: model.committedSettings?.windowManagement.scenes ?? [], execute: executeQuickCommand)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ArcBrandMark(size: 20)
                    .accessibilityHidden(true)
                Text("Arc Kit")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 与原生 sidebar 行的内容起点对齐，品牌不再向左突出。
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)

            sidebarNavigation(ApplicationFeatureCatalog.primary.map(\.section))

            // 底部入口与主导航共用选择状态和原生选中样式，不随内容滚动。
            sidebarNavigation(ApplicationFeatureCatalog.secondary.map(\.section))
                .frame(height: 44)

            HStack(spacing: 4) {
                Text(appVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsPersistenceIndicator(model: model)
            }
            .frame(height: 22)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    private func sidebarNavigation(_ sections: [MainWindowSection]) -> some View {
        List(selection: Binding<MainWindowSection?>(
            get: { navigation.selection },
            set: { if let section = $0 { navigate(to: section) } }
        )) {
            ForEach(sections) { section in
                sidebarLabel(section)
                    .tag(section)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
        }
        .listStyle(.sidebar)
        .appBackgroundSurface()
        .environment(\.defaultMinListRowHeight, 32)
        .controlSize(.small)
    }

    private func sidebarLabel(_ section: MainWindowSection) -> some View {
        HStack(spacing: 8) {
            ArcIcon(section.icon, size: 15)
                .frame(width: 20)
                .foregroundStyle(navigation.selection == section ? .primary : .secondary)
            Text(section.title)
                .font(.system(size: 13, weight: navigation.selection == section ? .medium : .regular))
            Spacer(minLength: 0)
        }
    }

    private func navigate(to section: MainWindowSection) {
        navigation.navigate(to: section, reduceMotion: shouldReduceMotion)
    }

    /// 系统辅助功能与 Arc Kit 独立偏好任一开启，都必须关闭非必要动画。
    private var shouldReduceMotion: Bool {
        systemReduceMotion || model.settings.reduceMotionEnabled
    }

    private var appVersion: String {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-debug") { return "Debug" }
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

}

private extension View {
    @ViewBuilder
    func applyAppearance(_ appearance: ArcAppearance) -> some View {
        switch appearance {
        case .system: self
        case .dark: self.preferredColorScheme(.dark)
        case .light: self.preferredColorScheme(.light)
        }
    }
}
