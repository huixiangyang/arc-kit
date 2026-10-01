import Foundation

public enum ArcKitConstants {
    public static let appBundleIdentifier = "com.archalo.arckit"
    public static let finderExtensionBundleIdentifier = "com.archalo.arckit.finder-extension"
    public static let settingsKey = "com.archalo.arckit.settings"
    public static let finderCommandDiagnosticsFileName = "ArcKitLogV2.log"
    public static let mainAppRuntimeStatePath = ArcKitStoragePaths.current.runtime.appendingPathComponent("app-state.json").path
    public static let finderSnapshotChangedDistributedNotificationName = "com.archalo.arckit.finderSnapshot.changed"
    public static let finderExtensionRuntimeStateRequestDistributedNotificationName = "com.archalo.arckit.finderExtension.runtimeState.request"
    public static let finderExtensionRuntimeStatePath = ArcKitStoragePaths.current.runtime.appendingPathComponent("finder-state.json").path
    public static let finderCommandExecutionRuntimeStatePath = ArcKitStoragePaths.current.runtime.appendingPathComponent("finder-execution.json").path
    public static let installedAppPath = "/Applications/Arc Kit.app"
    public static let installedAppExecutablePath = "\(installedAppPath)/Contents/MacOS/Arc Kit"
    public static let installedFinderExtensionPath = "\(installedAppPath)/Contents/PlugIns/ArcKitFinderExtension.appex"
    public static let installedFinderExtensionExecutablePath = "\(installedFinderExtensionPath)/Contents/MacOS/ArcKitFinderExtension"
    public static let runtimeHostBundleIdentifier = "com.archalo.arckit.runtime-host"
    public static let runtimeHostLaunchAgentIdentifier = runtimeHostBundleIdentifier
    public static let runtimeHostRelativePath = "Contents/Library/LoginItems/ArcKitRuntimeHost.app"
    public static let installedRuntimeHostPath = "\(installedAppPath)/\(runtimeHostRelativePath)"
    public static let installedRuntimeHostExecutablePath = "\(installedRuntimeHostPath)/Contents/MacOS/ArcKitRuntimeHost"
    public static let runtimeHostControlMachServiceName = "com.archalo.arckit.runtime-host.control"
    public static let finderRuntimeMachServiceName = "com.archalo.arckit.runtime-host.finder"
    public static let windowRuntimeMachServiceName = "com.archalo.arckit.runtime-host.window"
    public static let mouseRuntimeMachServiceName = "com.archalo.arckit.runtime-host.mouse"
}
