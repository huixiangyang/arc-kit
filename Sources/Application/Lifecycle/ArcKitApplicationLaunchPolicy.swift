import ArcKitPlatform
import ArcKitFinder
import ArcKitMouse
import ArcKitWindow
import Foundation

/// 主 App 的呈现来源必须显式建模，禁止再用延时或激活状态猜测。
public enum ArcKitApplicationLaunchMode: Equatable, Sendable {
    /// 登录启动只建立菜单栏与诊断代理，不显示 Dock 或主窗口。
    case background
    /// 用户显式打开、重开或调试预览时才进入交互模式。
    case interactive
}

public enum ArcKitApplicationLaunchPolicy {
    public static func initialMode(hasExplicitShowWindowArgument: Bool) -> ArcKitApplicationLaunchMode {
        hasExplicitShowWindowArgument ? .interactive : .background
    }

    public static func openApplicationMode(launchedAsLoginItem: Bool) -> ArcKitApplicationLaunchMode {
        launchedAsLoginItem ? .background : .interactive
    }
}
