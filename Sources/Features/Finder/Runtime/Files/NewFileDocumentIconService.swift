import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation

/// 为右键新建出来的文件写入可见的 Finder 自定义图标。
///
/// Finder 默认会对空白文本、空白表格等文件展示“白纸”预览，看起来像没有图标。
/// 这里主动使用对应应用图标写入文件 FinderInfo，让新建结果和右键菜单里的类型感保持一致。
public struct NewFileDocumentIconService {
    public init() {}

    @discardableResult
    public func applyIcon(to fileURL: URL, template: ConfigurableNewFileTemplate) -> Bool {
        guard let icon = NewFileTemplateIcon(template: template).loadImage() else {
            ArcKitLog.append("new file icon skipped path=\(fileURL.path) extension=\(template.normalizedExtension) reason=noIcon")
            return false
        }
        icon.size = NSSize(width: 512, height: 512)
        icon.isTemplate = false
        let ok = NSWorkspace.shared.setIcon(icon, forFile: fileURL.path, options: [])
        ArcKitLog.append("new file icon \(ok ? "applied" : "failed") path=\(fileURL.path) extension=\(template.normalizedExtension)")
        return ok
    }

}
