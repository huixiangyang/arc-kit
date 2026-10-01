import ArcKitPlatform
import Foundation
import CoreFoundation
import GRDB

/// 每个标量独立列、每个有序集合独立表。类型清单仅恢复 Codable 的 Bool/Double 区别，不承载配置值。
public enum ArcKitRecord {
    /// 只创建当前记录表，集合和业务约束由应用组合。
    public static func createTable(_ layout: ArcKitRecordLayout, in db: Database, columnConstraints: [String: String] = [:]) throws {
        let columns = layout.fields.map { field in
            var column = "\"\(field)\" \(layout.jsonFields.contains(field) ? "TEXT" : "ANY")"
            if let constraint = columnConstraints[field] { column += " " + constraint }
            return column
        }.joined(separator: ",")
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS \(layout.table) (_position INTEGER PRIMARY KEY, _types TEXT NOT NULL\(columns.isEmpty ? "" : "," + columns)) STRICT")
    }

    public static func load<T: Decodable>(_ type: T.Type, layout: ArcKitRecordLayout, db: Database) throws -> T? {
        let records = try objects(layout, db: db)
        guard records.count <= 1 else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordDuplicateSingleton)) }
        guard var object = records.first else { return nil }
        for (key, child) in layout.children { set(key, in: &object, value: try objects(child, db: db)) }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    public static func save<T: Encodable>(_ value: T, layout: ArcKitRecordLayout, db: Database) throws {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordRecordObject)) }
        try replace([object], layout: layout, db: db)
        for (key, child) in layout.children {
            guard let values = get(key, in: object) as? [[String: Any]] else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordInvalidCollectionFormat(String(describing: key)))) }
            try replace(values, layout: child, db: db)
        }
    }

    public static func objects(_ layout: ArcKitRecordLayout, db: Database) throws -> [[String: Any]] {
        try Row.fetchAll(db, sql: "SELECT * FROM \(layout.table) ORDER BY _position").map { row in
            guard let encodedTypes = String.fromDatabaseValue(row["_types"]) else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordInvalidConfigurationFieldTypeManifest)) }
            let types = try JSONDecoder().decode([String: String].self, from: Data(encodedTypes.utf8))
            var result: [String: Any] = [:]
            for field in layout.fields {
                guard !(row[field] as DatabaseValue).isNull else { continue }
                let value: Any
                let stored: DatabaseValue = row[field]
                switch (types[field], stored.storage) {
                case ("json", .string(let text)):
                    value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
                case ("bool", .int64(let number)) where number == 0 || number == 1: value = number == 1
                case ("number", .double(let number)) where number.isFinite: value = number
                case ("number", .int64(let number)): value = number
                case ("text", .string(let text)): value = text
                default: throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordConfigurationFieldTypeMismatch(String(describing: layout.table), String(describing: field))))
                }
                set(field, in: &result, value: value)
            }
            return result
        }
    }

    public static func replace(_ objects: [[String: Any]], layout: ArcKitRecordLayout, db: Database) throws {
        try db.execute(sql: "DELETE FROM \(layout.table)")
        for (position, object) in objects.enumerated() {
            var types: [String: String] = [:]
            var values: [DatabaseValue] = []
            for field in layout.fields {
                guard let value = get(field, in: object), !(value is NSNull) else { values.append(.null); continue }
                if layout.jsonFields.contains(field) {
                    types[field] = "json"
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                    values.append(String(decoding: data, as: UTF8.self).databaseValue)
                } else if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { types[field] = "bool"; values.append(number.int64Value.databaseValue) }
                    else { types[field] = "number"; values.append(number.doubleValue.databaseValue) }
                } else if let string = value as? String { types[field] = "text"; values.append(string.databaseValue) }
                else { throw ArcKitDatabaseError.message(L10n.string(.Persistence.recordFieldDeclareComplexValueType(String(describing: field)))) }
            }
            let columns = ["_position", "_types"] + layout.fields
            let args = [position.databaseValue, String(decoding: try JSONEncoder().encode(types), as: UTF8.self).databaseValue] + values
            try db.execute(sql: "INSERT INTO \(layout.table) (\(columns.map { "\"\($0)\"" }.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(args))
        }
    }

    private static func get(_ path: String, in object: [String: Any]) -> Any? {
        path.split(separator: ".").reduce(object as Any?) { ($0 as? [String: Any])?[String($1)] }
    }
    private static func set(_ path: String, in object: inout [String: Any], value: Any) {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 1 { object[path] = value }
        else { var child = object[parts[0]] as? [String: Any] ?? [:]; set(parts[1], in: &child, value: value); object[parts[0]] = child }
    }
}
