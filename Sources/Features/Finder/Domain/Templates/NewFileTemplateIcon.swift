import AppKit
import UniformTypeIdentifiers

/// 模板列表、Finder 菜单和新建结果共用同一图标来源；值本身也作为缓存键。
public struct NewFileTemplateIcon: Hashable, Sendable {
    let fileExtension: String
    let applicationBundleIdentifiers: [String]
    let allowsDefaultApplication: Bool

    public init(template: ConfigurableNewFileTemplate) {
        fileExtension = template.normalizedExtension.lowercased()
        applicationBundleIdentifiers = template.iconApplicationBundleIdentifiers
        allowsDefaultApplication = template.allowsDefaultApplicationIconFallback
    }

    /// 涉及 LaunchServices / IconServices 查询，菜单必须在后台预加载后读取缓存。
    public func loadImage() -> NSImage? {
        let workspace = NSWorkspace.shared
        for bundleID in applicationBundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return workspace.icon(forFile: url.path)
            }
        }
        guard !fileExtension.isEmpty else { return workspace.icon(for: .data) }
        let sampleURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArcKitDocumentIconPreview")
            .appendingPathExtension(fileExtension)
        if allowsDefaultApplication, let url = workspace.urlForApplication(toOpen: sampleURL) {
            return workspace.icon(forFile: url.path)
        }
        if let type = UTType(filenameExtension: fileExtension) { return workspace.icon(for: type) }
        return workspace.icon(forFile: sampleURL.path)
    }
}
