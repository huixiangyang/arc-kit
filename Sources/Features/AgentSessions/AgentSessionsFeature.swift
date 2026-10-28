import ArcKitPlatform

enum AgentSessionsFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .agentSessions, title: L10n.string(.AgentSessions.pageTitle), icon: .archive, commands: { [
            .command("section.agent-sessions", L10n.string(.AgentSessions.pageTitle), L10n.string(.AgentSessions.pageDescription),
                .archive, L10n.string(.App.searchPages), ["Agent", "Codex", "会话", "备份", "恢复", "sessions", "backup"], .section(.agentSessions), order: 65)
        ] })
    }
}
