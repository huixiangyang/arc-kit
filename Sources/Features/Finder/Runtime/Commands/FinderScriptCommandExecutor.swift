import ArcKitFinder
import ArcKitPlatform
import Foundation

struct FinderScriptCommandExecutor {
    let fileManager: FileManager
    let scriptRunner: (URL, [String]) -> Bool

    init(
        fileManager: FileManager = .default,
        run: @escaping (URL, [String]) -> Bool = {
            ShellExecutor.run(executableURL: $0, arguments: $1, timeout: 110)
        }
    ) {
        self.fileManager = fileManager
        self.scriptRunner = run
    }

    func execute(_ request: FinderCommandRequest) throws -> FinderCommandExecutionResult? {
        guard case let .runScript(payload) = request.payload else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.scriptExecutionUnexpectedCommand(String(describing: request.kind.rawValue))))
        }
        let plan = try scriptExecutionPlan(scriptPath: payload.scriptPath)
        guard scriptRunner(plan.executableURL, plan.arguments) else {
            throw FinderCommandExecutionError.commandFailed(L10n.string(.FinderActions.scriptExecutionScriptExecutionFailed(String(describing: payload.scriptPath))))
        }
        return nil
    }

    private func scriptExecutionPlan(scriptPath: String) throws -> (executableURL: URL, arguments: [String]) {
        let path = try FinderScriptValidation.validate(scriptPath, fileManager: fileManager)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "sh":
            return (
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: [path]
            )
        case "py":
            let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            guard let interpreter = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
                throw FinderScriptExecutionError.interpreterUnavailable("Python 3")
            }
            return (
                executableURL: URL(fileURLWithPath: interpreter),
                arguments: [path]
            )
        case "js":
            return (
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-l", "JavaScript", path]
            )
        default:
            throw FinderScriptExecutionError.unsupportedExtension(ext)
        }
    }

}
