/// 仅暴露本工作区需要的动作，由应用生命周期装配。
struct GeneralSettingsActions {
    let toggleHiddenFiles: () -> Void
    let chooseScreenshotLocation: () -> Void
    let resetScreenshotLocation: () -> Void
    let openLoginItemsSettings: () -> Void
    let retryLaunchAtLoginChange: () -> Void
}
