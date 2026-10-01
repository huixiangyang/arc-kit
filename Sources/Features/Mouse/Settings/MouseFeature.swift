import ArcKitPlatform

enum MouseFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .mouse, title: L10n.string(.Common.mouse), icon: .mouse, commands: { commands })
    }

    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "section.mouse", L10n.string(.App.searchMouseEnhancement), L10n.string(.App.searchSmoothScrollingGesturesPerAppFeel), .mouse, L10n.string(.App.searchPages),
                ["滚轮", "反向", "横向", "加速", "应用规则", "scroll", "gesture"], .section(.mouse), suggested: true, order: 30
            )
        ]
    }
}
