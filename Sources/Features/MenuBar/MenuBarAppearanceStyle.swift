import Foundation

/// 保留已有配置中的预览参数，不代表已支持修改系统外观。
public enum MenuBarAppearanceStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, floating, split
    public var id: Self { self }
}
