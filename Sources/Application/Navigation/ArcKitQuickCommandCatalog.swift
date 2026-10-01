import Foundation

/// 命令内容由功能声明；应用只负责聚合和统一搜索排序。
enum ArcKitQuickCommandCatalog {
    static var all: [ArcKitQuickCommand] {
        ApplicationFeatureCatalog.all.flatMap { $0.commands() }
    }

    static func results(for query: String) -> [ArcKitQuickCommand] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return all.filter(\.isSuggested).sorted { $0.stableOrder < $1.stableOrder }
        }
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        return all.compactMap { command -> (ArcKitQuickCommand, Int)? in
            let title = normalize(command.title)
            let detail = normalize(command.detail)
            let keywords = normalize(command.keywords.joined(separator: " "))
            let haystack = "\(title) \(detail) \(keywords)"
            guard terms.allSatisfy(haystack.contains) else { return nil }

            let score: Int
            if title == normalizedQuery {
                score = 0
            } else if title.hasPrefix(normalizedQuery) {
                score = 10
            } else if title.contains(normalizedQuery) {
                score = 20
            } else if detail.contains(normalizedQuery) {
                score = 30
            } else {
                score = 40
            }
            return (command, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.stableOrder < $1.0.stableOrder
        }
        .map(\.0)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

}
