import ArcKitPlatform
import SwiftUI

// MARK: - Sections

/// 首页与功能位于侧栏顶部，系统设置固定在底部。
public enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    case overview
    case finder
    case window
    case mouse
    case wallpaper
    case preferences

    public static let allCases: [MainWindowSection] = [
        .overview, .finder, .window, .mouse, .wallpaper, .preferences,
    ]

    public var id: String { rawValue }

    var icon: ArcIconName { ApplicationFeatureCatalog.entry(for: self).icon }
    var title: String { ApplicationFeatureCatalog.entry(for: self).title }
}

// MARK: - Main window

@MainActor
final class MainWindowNavigationModel: ObservableObject {
    @Published var selection: MainWindowSection = .overview
    @Published var quickFindRequestID = 0
    @Published var preferencesTarget: PreferencesWorkspaceTarget = .application
    @Published var windowTarget: WindowWorkspaceTab = .snapping

    func navigate(to section: MainWindowSection, reduceMotion: Bool) {
        guard selection != section else { return }
        if reduceMotion { selection = section }
        else { withAnimation(.easeInOut(duration: 0.16)) { selection = section } }
    }

    func requestQuickFind() {
        quickFindRequestID += 1
    }

    func requestPreferences(_ target: PreferencesWorkspaceTarget) {
        preferencesTarget = target
    }
}
