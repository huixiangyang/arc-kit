import ArcKitPlatform
import Foundation

public struct SystemEnhancementCommandBuilder: Sendable {
    public init() {}

    public func readHiddenFilesCommand() -> String {
        // 缺少该 key 就是 Finder 的系统默认值：不显示隐藏文件。
        "defaults read com.apple.finder AppleShowAllFiles 2>/dev/null || printf false"
    }

    public func setHiddenFilesCommand(enabled: Bool) -> String {
        "defaults write com.apple.finder AppleShowAllFiles -bool \(enabled ? "true" : "false")"
    }

    public func restartFinderCommand() -> String {
        "killall Finder"
    }

    public func readScreenshotLocationCommand() -> String {
        "defaults read com.apple.screencapture location"
    }

    public func setScreenshotLocationCommand(path: String) -> String {
        "defaults write com.apple.screencapture location \(ShellQuoting.shellQuoted(path))"
    }

    public func resetScreenshotLocationCommand() -> String {
        "defaults delete com.apple.screencapture location"
    }

    public func restartSystemUIServerCommand() -> String {
        "killall SystemUIServer"
    }
}
