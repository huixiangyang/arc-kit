/// 应用装配动作；页面收到下级专用接口，不持有整个应用的操作权限。
struct ApplicationActions {
    let health: RuntimeHealthActions
    let general: GeneralSettingsActions
    let data: DataManagementActions
    let window: WindowCommandActions
}
