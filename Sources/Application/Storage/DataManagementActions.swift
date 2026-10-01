/// 仅暴露本工作区需要的动作，由应用生命周期装配。
struct DataManagementActions {
    let exportBackup: (DataBackupScope) -> Void
    let revealExportedBackup: () -> Void
    let restoreBackup: () -> Void
    let exportSupportDiagnostics: () -> Void
    let uninstallArcKit: (Bool) -> Void
}
