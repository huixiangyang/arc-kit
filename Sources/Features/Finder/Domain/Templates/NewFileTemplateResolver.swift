import ArcKitPlatform
import Foundation

/// Finder 菜单项到新建文件模板 ID 的唯一解析规则。
/// 不做静默兜底：菜单元数据异常必须暴露出来，避免用户点击后创建了错误类型的文件。
public enum NewFileTemplateResolver {
    public static let menuIdentifierPrefix = "arckit.newFile."

    public struct Input: Equatable, Sendable {
        public var representedObject: String?
        public var identifier: String?
        public var title: String?

        public init(representedObject: String?, identifier: String?, title: String?) {
            self.representedObject = representedObject
            self.identifier = identifier
            self.title = title
        }

        public var diagnosticDescription: String {
            [
                "representedObject=\(representedObject.nilIfBlank ?? "nil")",
                "identifier=\(identifier.nilIfBlank ?? "nil")",
                "title=\(title.nilIfBlank ?? "nil")"
            ].joined(separator: ", ")
        }
    }

    public struct Failure: Error, Equatable, LocalizedError, Sendable {
        public var input: Input
        public var availableTemplateIDs: [String]

        public var errorDescription: String? {
            L10n.string(.Finder.templateNewFileTemplateMissingReceivedAvailable(String(describing: input.diagnosticDescription), String(describing: availableTemplateIDs.joined(separator: ", "))))
        }
    }

    public static func resolve(input: Input, templates: [ConfigurableNewFileTemplate]) -> Result<String, Failure> {
        let ids = Set(templates.map(\.id))
        if let representedObject = input.representedObject.nilIfBlank, ids.contains(representedObject) {
            return .success(representedObject)
        }

        if let identifier = input.identifier.nilIfBlank,
           identifier.hasPrefix(menuIdentifierPrefix) {
            let suffix = String(identifier.dropFirst(menuIdentifierPrefix.count))
            if ids.contains(suffix) {
                return .success(suffix)
            }
        }

        if let title = input.title.nilIfBlank {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let template = templates.first(where: { $0.displayName == normalizedTitle || $0.defaultFileName == normalizedTitle }) {
                return .success(template.id)
            }
        }

        return .failure(Failure(input: input, availableTemplateIDs: templates.map(\.id).sorted()))
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
