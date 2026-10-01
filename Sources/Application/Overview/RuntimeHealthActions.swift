/// 仅暴露本工作区需要的动作，由应用生命周期装配。
struct RuntimeHealthActions {
    let requestAccessibilityPermission: () -> Void
    let openAccessibilitySettings: () -> Void
    let requestMenuInputPermission: () -> Void
    let openInputMonitoringSettings: () -> Void
    let openAutomationSettings: () -> Void
    let openExtensionSettings: () -> Void
    let showFinderExtensionDiagnostics: () -> Void
    let repairFinderExtension: (@escaping () -> Void) -> Void
    let openLoginItemsSettings: () -> Void
    let refreshRuntimeState: () -> Void
}
