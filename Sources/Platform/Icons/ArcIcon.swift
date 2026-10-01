import AppKit

/// Arc Kit 唯一允许使用的界面图标集合。
///
/// rawValue 与 Lucide 的稳定资源 ID 一致。使用闭合集合可以在编译期阻止任意图标字符串
/// 继续渗入界面，也便于测试一次性验证所有图标资源完整可用。
public enum ArcIconName: String, CaseIterable, Codable, Hashable, Sendable {
    case activity
    case appWindow = "app-window"
    case appWindowMac = "app-window-mac"
    case archive
    case arrowDown = "arrow-down"
    case arrowDownLeft = "arrow-down-left"
    case arrowDownRight = "arrow-down-right"
    case arrowLeftRight = "arrow-left-right"
    case arrowUp = "arrow-up"
    case arrowUpLeft = "arrow-up-left"
    case arrowUpRight = "arrow-up-right"
    case braces
    case checkCircle = "circle-check"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case chevronUp = "chevron-up"
    case circleHalf = "circle-dashed"
    case circleHelp = "circle-question-mark"
    case circleInfo = "info"
    case circleX = "circle-x"
    case cloudDownload = "cloud-download"
    case code
    case codeXml = "code-xml"
    case columns3 = "columns-3"
    case command
    case copy
    case cornerDownLeft = "corner-down-left"
    case eye
    case eyeOff = "eye-off"
    case file
    case filePlus = "file-plus"
    case fileQuestion = "file-question-mark"
    case fileText = "file-text"
    case focus
    case folder
    case folderCog = "folder-cog"
    case folderInput = "folder-input"
    case folderOpen = "folder-open"
    case folderPlus = "folder-plus"
    case gauge
    case hardDrive = "hard-drive"
    case hardDriveUpload = "hard-drive-upload"
    case hash
    case house
    case image
    case layoutDashboard = "layout-dashboard"
    case lockKeyhole = "lock-keyhole"
    case lockKeyholeOpen = "lock-keyhole-open"
    case maximize2 = "maximize-2"
    case menu
    case monitor
    case moon
    case mouse
    case moveHorizontal = "move-horizontal"
    case panelBottom = "panel-bottom"
    case panelLeft = "panel-left"
    case panelRight = "panel-right"
    case panelTop = "panel-top"
    case panelsTopLeft = "panels-top-left"
    case paintbrush
    case pencil
    case pipette
    case plus
    case presentation
    case power
    case puzzle
    case redo2 = "redo-2"
    case refreshCw = "refresh-cw"
    case rotateCcw = "rotate-ccw"
    case rows3 = "rows-3"
    case search
    case settings
    case shieldCheck = "shield-check"
    case sparkles
    case squareCode = "square-code"
    case squareDashed = "square-dashed"
    case sun
    case table2 = "table-2"
    case terminal
    case textCursorInput = "text-cursor-input"
    case trash2 = "trash-2"
    case triangleAlert = "triangle-alert"
    case undo2 = "undo-2"
    case wrench
}

/// AppKit、SwiftUI、菜单栏和独立 Agent 共用的 Lucide 位图入口。
public enum ArcIconImage {
    public static func image(_ name: ArcIconName) -> NSImage {
        guard let url = resourceURL(for: name),
              let source = NSImage(contentsOf: url),
              let image = source.copy() as? NSImage
        else {
            // 资源缺失属于打包故障，只降级当前图标，绝不能让菜单栏、Finder Agent 或主 App 崩溃。
            ArcKitLog.append("lucide icon resource missing name=\(name.rawValue)")
            let fallback = NSImage(size: NSSize(width: 1, height: 1))
            fallback.isTemplate = true
            return fallback
        }
        image.isTemplate = true
        return image
    }

    private static func resourceURL(for name: ArcIconName) -> URL? {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name.rawValue, withExtension: "pdf", subdirectory: "Lucide")
#else
        let bundle = Bundle(for: ArcIconBundleLocator.self)
        return bundle.url(forResource: name.rawValue, withExtension: "pdf")
            ?? bundle.url(forResource: name.rawValue, withExtension: "pdf", subdirectory: "Lucide")
#endif
    }
}

private final class ArcIconBundleLocator {}
