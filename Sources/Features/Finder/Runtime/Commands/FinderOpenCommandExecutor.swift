import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation

struct FinderOpenCommandExecutor {
    let fileManager: FileManager
    let terminal: FinderTerminalLauncher
    let opener: FinderApplicationOpener

    init(
        fileManager: FileManager = .default,
        terminal: FinderTerminalLauncher = FinderTerminalLauncher(),
        opener: FinderApplicationOpener = FinderApplicationOpener()
    ) {
        self.fileManager = fileManager
        self.terminal = terminal
        self.opener = opener
    }

    func execute(_ request: FinderCommandRequest, targets: FinderCommandTargets) throws -> FinderCommandExecutionResult? {
        switch request.payload {
        case let .openTerminal(payload):
            let directory = try targets.terminalDirectoryURL(request)
            try terminal.open(directory: directory, terminal: payload.terminalApp, mode: payload.openMode)
        case let .openWithApp(payload):
            let urls = try targets.sourceTargetOrResolvedURLs(request, actionName: L10n.string(.FinderActions.commandOpenApp))
            let app = payload.favoriteApplication
            ArcKitLog.append(
                "processor openWithApp app=\(app.displayName) bundleID=\(app.bundleIdentifier ?? "-") " +
                "appPath=\(app.appPath ?? "-") selectedCount=\(request.sourcePaths.count) targetCount=\(urls.count)"
            )
            if let terminal = TerminalApp(application: app) {
                guard urls.count == 1, let target = urls.first else {
                    throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.openSelectOneTerminalFolderFile))
                }
                let directory = try FinderCommandTargets.terminalDirectoryURL(for: target)
                ArcKitLog.append("processor openWithApp routedToTerminal app=\(app.displayName) directory=\(directory.path)")
                try self.terminal.open(directory: directory, terminal: terminal, mode: .open)
                return nil
            }
            try opener.openURLs(urls, applicationURL: try applicationURL(for: app), label: app.displayName)
        case .openPath:
            try opener.openURLs([try targets.targetURL(request)], applicationURL: nil, label: L10n.string(.FinderActions.commandOpenPath))
        default:
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.openOpenExecutorReceivedUnexpectedCommand(String(describing: request.kind.rawValue))))
        }
        return nil
    }

    private func applicationURL(for app: FavoriteApplication) throws -> URL? {
        if let path = app.appPath, fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleID = app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        if let bundleID = app.bundleIdentifier {
            throw FinderCommandExecutionError.applicationUnavailable(bundleID)
        }
        throw FinderCommandExecutionError.applicationUnavailable(app.displayName)
    }

}
