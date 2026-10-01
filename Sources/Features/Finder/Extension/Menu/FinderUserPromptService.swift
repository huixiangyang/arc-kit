import ArcKitPlatform
import ArcKitFinder
import AppKit
import UniformTypeIdentifiers

/// Finder 扩展侧唯一用户交互服务。
///
/// 菜单点击链路里的提示、确认和临时输入都集中到这里，避免请求构造器或分发器
/// 夹杂 UI 逻辑，也方便后续把部分输入迁移到 Agent。
@MainActor
enum FinderUserPromptService {
    static func feedback(title: String, message: String) {
        FinderExtensionFeedbackHUDPresenter.shared.show(title: title, message: message)
    }

    static func makeFeedbackPanel(title: String, message: String) -> NSPanel {
        FinderExtensionFeedbackHUDPresenter.makePanel(title: title, message: message)
    }

    static func information(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string(.FinderExtension.transferGot))
        alert.runModal()
    }

    static func confirmDestructiveDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string(.FinderExtension.promptPermanentlyDeleteSelectedFiles)
        alert.informativeText = L10n.string(.FinderExtension.promptPermanentDeletionHint)
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.string(.Common.delete))
        alert.addButton(withTitle: L10n.string(.Common.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func chooseScriptPath() -> String? {
        let scriptTypes = ["sh", "py", "js"].compactMap { UTType(filenameExtension: $0) }
        guard scriptTypes.count == 3 else {
            information(title: L10n.string(.FinderExtension.promptScriptPickerFailed), message: L10n.string(.FinderExtension.promptScriptTypesUnavailable))
            return nil
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = scriptTypes
        panel.message = L10n.string(.FinderExtension.promptChooseScriptRun)
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    static func askFolderName() -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string(.FinderExtension.commandGroupInFolder)
        alert.informativeText = L10n.string(.FinderExtension.promptEnterNewFolderName)
        alert.addButton(withTitle: L10n.string(.Common.ok))
        alert.addButton(withTitle: L10n.string(.Common.cancel))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        textField.placeholderString = L10n.string(.FinderExtension.promptNewFolder)
        alert.accessoryView = textField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// 扩展解析失败与 Agent 超时都属于结果反馈，不能用模态 Alert 抢走或阻塞 Finder。
@MainActor
private final class FinderExtensionFeedbackHUDPresenter {
    static let shared = FinderExtensionFeedbackHUDPresenter()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(title: String, message: String) {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel(title: title, message: message)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 18,
            y: visibleFrame.maxY - panel.frame.height - 18
        ))
        self.panel = panel
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: workItem)
    }

    static func makePanel(title: String, message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 88),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.setAccessibilityLabel("\(title)。\(message)")

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 16, y: 32, width: 24, height: 24))
        icon.image = ArcIconImage.image(.triangleAlert)
        icon.contentTintColor = .systemOrange
        effect.addSubview(icon)

        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 52, y: 54, width: 286, height: 18)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityIdentifier("ArcKitFinderExtensionHUDTitle")
        effect.addSubview(titleField)

        let messageField = NSTextField(labelWithString: message)
        messageField.frame = NSRect(x: 52, y: 16, width: 292, height: 36)
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = .secondaryLabelColor
        messageField.lineBreakMode = .byTruncatingTail
        messageField.maximumNumberOfLines = 2
        messageField.setAccessibilityIdentifier("ArcKitFinderExtensionHUDMessage")
        effect.addSubview(messageField)

        panel.contentView = effect
        return panel
    }
}
