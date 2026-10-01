import Foundation

/// 业务声明记录结构，SQL 实现留在 Persistence。复杂参数才使用 JSON，列表各自有顺序列。
public struct ArcKitRecordLayout: Sendable {
    public let table: String
    public let fields: [String]
    public let jsonFields: Set<String>
    public let children: [String: ArcKitRecordLayout]
    public init(_ table: String, fields: [String], json: Set<String> = [], children: [String: ArcKitRecordLayout] = [:]) {
        self.table = table; self.fields = fields; self.jsonFields = json; self.children = children
    }
}
