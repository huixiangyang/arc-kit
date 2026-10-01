import ArcKitWindow

/// 仅暴露本工作区需要的动作，由应用生命周期装配。
struct WindowCommandActions {
    let prepareQuickFind: () -> Void
    let performWindowAction: (WindowLayoutAction) -> Void
}
