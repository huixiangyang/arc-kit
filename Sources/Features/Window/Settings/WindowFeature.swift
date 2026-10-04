import ArcKitPlatform
import ArcKitWindow

enum WindowFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .window, title: L10n.string(.Common.windows), icon: .appWindowMac, commands: { commands })
    }

    static var commands: [ArcKitQuickCommand] {
        var commands = [
            ArcKitQuickCommand.command(
                "section.window", L10n.string(.App.searchWindowManagement), L10n.string(.App.searchLayoutsShortcutsSnappingExcludedApps), .appWindowMac, L10n.string(.App.searchPages),
                ["快捷键", "吸附", "布局", "多显示器", "window", "hotkey", "snap"], .section(.window), suggested: true, order: 20
            ),
            ArcKitQuickCommand.command(
                "section.window.scenes", L10n.string(.App.scenesTitle), L10n.string(.App.scenesDescription), .panelsTopLeft,
                L10n.string(.App.searchPages), ["窗口场景", "预设", "工作布局", "scenes", "presets", "workspace"],
                .windowScenes, order: 21
            )
        ]
        for (index, action) in WindowLayoutAction.allCases.enumerated() {
            commands.append(ArcKitQuickCommand.command(
                "window.\(action.rawValue)",
                action.displayName,
                windowActionDetail(action),
                windowActionSymbol(action),
                L10n.string(.App.searchWindowActions),
                windowActionKeywords(action),
                .window(action),
                suggested: [.fill, .leftHalf, .rightHalf, .center].contains(action),
                order: 100 + index
            ))
        }
        return commands
    }

    static func sceneCommands(_ scenes: [WindowScene]) -> [ArcKitQuickCommand] {
        scenes.enumerated().map { index, scene in
            .command("window.scene.\(scene.id.uuidString)", scene.name, L10n.string(.App.scenesApplyHint),
                     .panelsTopLeft, L10n.string(.App.scenesTitle),
                     ["场景", "恢复布局", "scene", "preset", "workspace"], .windowScene(scene.id),
                     suggested: true, order: 80 + index)
        }
    }
    private static func windowActionDetail(_ action: WindowLayoutAction) -> String {
        switch action {
        case .fullScreen: L10n.string(.App.searchEnterLeaveMacosFullScreen)
        case .fill: L10n.string(.App.searchFillCurrentDisplaySAvailableArea)
        case .stageManager: L10n.string(.App.searchStageManagerHint)
        case .restore: L10n.string(.App.searchRestoreCurrentWindowSPreviousPosition)
        case .nextDisplay, .previousDisplay: L10n.string(.App.searchMoveCurrentWindowRequiresSecond)
        default: L10n.string(.App.searchArrangeMostRecentlyUsedExternalApp)
        }
    }

    private static func windowActionKeywords(_ action: WindowLayoutAction) -> [String] {
        var values = [L10n.string(.Common.windows), L10n.string(.App.searchLayouts), L10n.string(.App.searchRun), action.rawValue]
        switch action {
        case .leftHalf: values += [L10n.string(.App.searchLeft), "left half"]
        case .rightHalf: values += [L10n.string(.App.searchRight), "right half"]
        case .topHalf: values += [L10n.string(.App.searchTop), "top half"]
        case .bottomHalf: values += [L10n.string(.App.searchBottom), "bottom half"]
        case .topLeft: values += [L10n.string(.App.searchTopLeft), "top left"]
        case .topRight: values += [L10n.string(.App.searchTopRight), "top right"]
        case .bottomLeft: values += [L10n.string(.App.searchBottomLeft), "bottom left"]
        case .bottomRight: values += [L10n.string(.App.searchBottomRight), "bottom right"]
        case .leftThird, .centerThird, .rightThird: values += [L10n.string(.App.searchOneThird), "third"]
        case .leftTwoThirds, .rightTwoThirds: values += [L10n.string(.App.searchTwoThirds), "two thirds"]
        case .fullScreen: values += [L10n.string(.WindowSettings.layoutFullScreenDisplay), L10n.string(.App.searchFullScreenSpace), "space", "fullscreen"]
        case .center: values += [L10n.string(.App.searchCenter), "center"]
        case .fill: values += [L10n.string(.WindowSettings.layoutMaximize), L10n.string(.App.searchKeepMenuBar), "fill"]
        case .stageManager: values += [L10n.string(.WindowSettings.layoutStageManager), "Stage Manager", "85%", L10n.string(.App.searchThumbnails)]
        case .nextDisplay, .previousDisplay: values += [L10n.string(.App.searchAcrossDisplays), L10n.string(.App.searchDisplay), "monitor", "display"]
        case .restore: values += [L10n.string(.App.searchUndoLayout), L10n.string(.App.searchRestore), "restore"]
        }
        return values
    }

    private static func windowActionSymbol(_ action: WindowLayoutAction) -> ArcIconName {
        switch action {
        case .leftHalf: .panelLeft
        case .rightHalf: .panelRight
        case .topHalf: .panelTop
        case .bottomHalf: .panelBottom
        case .topLeft: .arrowUpLeft
        case .topRight: .arrowUpRight
        case .bottomLeft: .arrowDownLeft
        case .bottomRight: .arrowDownRight
        case .leftThird, .centerThird, .rightThird: .columns3
        case .leftTwoThirds, .rightTwoThirds: .columns3
        case .fullScreen: .maximize2
        case .center: .focus
        case .fill: .appWindowMac
        case .stageManager: .panelLeft
        case .nextDisplay, .previousDisplay: .monitor
        case .restore: .undo2
        }
    }
}
