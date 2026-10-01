import ArcKitPlatform

enum AppearanceFeature {
    static var commands: [ArcKitQuickCommand] {
        return [
            ArcKitQuickCommand.command(
                "preferences.background", L10n.string(.App.searchArcKitAppBackground), L10n.string(.App.searchImageVideoBackgroundsSoftGlowOpacity), .image, L10n.string(.Common.settings),
                ["应用背景", "背景图片", "透明度", "模糊", "光晕", "粒子", "background"], .preferences(.background), order: 45
            )
        ]
    }
}
