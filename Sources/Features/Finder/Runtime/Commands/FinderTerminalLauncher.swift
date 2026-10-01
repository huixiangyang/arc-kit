import ArcKitFinder
import ArcKitPlatform
@preconcurrency import AppKit
import Foundation

/// 普通打开走 Launch Services；只有显式新建操作才向目标终端发送 Apple Events。
struct FinderTerminalLauncher {
    let opener: FinderApplicationOpener
    let automation: FinderTerminalAutomation

    init(opener: FinderApplicationOpener = .init(), automation: FinderTerminalAutomation = .init()) {
        self.opener = opener
        self.automation = automation
    }

    func open(directory: URL, terminal: TerminalApp, mode: FinderTerminalOpenMode) throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) else {
            throw FinderCommandExecutionError.applicationUnavailable(terminal.displayName)
        }
        if mode == .open {
            try opener.openURLs([directory], applicationURL: application, label: terminal.displayName)
            return
        }
        try automation.execute(directory: directory, terminal: terminal, mode: mode)
    }
}

struct FinderTerminalAutomation {
    /// 注入执行边界便于验证拒绝授权与脚本失败，不在测试中发送真实 Apple Events。
    let run: (String) throws -> Void
    init(run: @escaping (String) throws -> Void = Self.runAppleScript) { self.run = run }

    func execute(directory: URL, terminal: TerminalApp, mode: FinderTerminalOpenMode) throws {
        let source = try Self.source(directory: directory, terminal: terminal, mode: mode)
        do { try run(source) }
        catch let error as NSError where error.domain == "ArcKit.AppleScript" && error.code == -1743 {
            throw FinderCommandExecutionError.commandFailed(
                L10n.string(.FinderActions.terminalAuthorizationDenied(String(describing: terminal.displayName))))
        }
    }

    static func source(directory: URL, terminal: TerminalApp, mode: FinderTerminalOpenMode) throws -> String {
        // 目录先按 shell 单一参数转义，再编码为 AppleScript 字符串；不再嵌套 shell/osascript 引号。
        let command = literal("cd -- " + ShellQuoting.shellQuoted(directory.path))
        let body: String
        switch (terminal, mode) {
        case (.terminal, .window): body = "do script \(command)"
        case (.iTerm, .tab):
            body = """
            if (count of windows) = 0 then
                set targetWindow to (create window with default profile)
                set targetSession to current session of targetWindow
            else
                tell current window to set targetTab to (create tab with default profile)
                set targetSession to current session of targetTab
            end if
            tell targetSession to write text \(command)
            """
        case (.iTerm, .window):
            body = """
            set targetWindow to (create window with default profile)
            tell current session of targetWindow to write text \(command)
            """
        default:
            // Terminal 的 tabs 元素只读，do script in front window 会写入现有会话，并非新建标签。
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.terminalUnsupportedAction))
        }
        return """
        tell application id "\(terminal.bundleIdentifier)"
            activate
            \(body)
        end tell
        """
    }

    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.terminalScriptCreationFailed))
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
            let message = error[NSAppleScript.errorMessage] as? String ?? L10n.string(.FinderActions.terminalTerminalAutomationFailed)
            throw NSError(domain: "ArcKit.AppleScript", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
