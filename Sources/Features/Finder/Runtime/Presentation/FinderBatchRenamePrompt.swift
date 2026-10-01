import ArcKitFinder
import ArcKitPlatform
import AppKit

/// 批量重命名在一次性 Worker 中展示原生预览；Finder Extension 仅投递选中项。
@MainActor
enum FinderBatchRenamePrompt {
    static func present(sourcePaths: [String]) -> FinderBatchRenameRule? {
        FinderProcessAppKitLifecycle.ensureReady(activate: true)

        let alert = NSAlert()
        alert.messageText = L10n.string(.FinderActions.renameSelectionCount(Int(sourcePaths.count)))
        alert.informativeText = L10n.string(.FinderActions.renamePromptReviewPreviewBelowArcKitPreserves)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string(.FinderActions.renamePromptRename))
        alert.addButton(withTitle: L10n.string(.Common.cancel))

        let accessory = FinderBatchRenameAccessoryView(sourcePaths: sourcePaths)
        alert.accessoryView = accessory
        let confirmButton = alert.buttons[0]
        confirmButton.isEnabled = false
        accessory.validationChanged = { isValid in
            confirmButton.isEnabled = isValid
        }
        accessory.refreshPreview()
        alert.window.initialFirstResponder = accessory.initialFirstResponder

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return accessory.currentRule
    }
}

@MainActor
private final class FinderBatchRenameAccessoryView: NSView, NSTextFieldDelegate {
    let sourcePaths: [String]
    var validationChanged: ((Bool) -> Void)?

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let primaryLabel = NSTextField(labelWithString: "")
    private let primaryField = NSTextField(frame: .zero)
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let secondaryField = NSTextField(frame: .zero)
    private let digitsLabel = NSTextField(labelWithString: L10n.string(.FinderActions.renamePromptNumberWidth))
    private let digitsField = NSTextField(frame: .zero)
    private let preserveExtension = NSButton(checkboxWithTitle: L10n.string(.FinderActions.renamePromptPreserveFileExtensions), target: nil, action: nil)
    private let previewText = NSTextView(frame: .zero)
    private let validationText = NSTextField(wrappingLabelWithString: "")

    init(sourcePaths: [String]) {
        self.sourcePaths = sourcePaths
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: 330))
        configureViews()
        selectMode(.replace)
    }

    required init?(coder: NSCoder) {
        sourcePaths = []
        super.init(coder: coder)
        configureViews()
        selectMode(.replace)
    }

    var currentRule: FinderBatchRenameRule? {
        guard let mode = FinderBatchRenameMode(rawValue: modePopup.selectedItem?.representedObject as? String ?? "") else {
            return nil
        }
        return FinderBatchRenameRule(
            mode: mode,
            primaryText: primaryField.stringValue,
            replacementText: secondaryField.stringValue,
            startNumber: Int(secondaryField.stringValue) ?? -1,
            minimumDigits: Int(digitsField.stringValue) ?? -1,
            preserveFileExtension: preserveExtension.state == .on
        )
    }

    var initialFirstResponder: NSView { primaryField }

    override func layout() {
        super.layout()
        modePopup.frame = NSRect(x: 110, y: 288, width: 210, height: 26)
        primaryLabel.frame = NSRect(x: 0, y: 250, width: 98, height: 22)
        primaryField.frame = NSRect(x: 110, y: 248, width: 410, height: 24)
        secondaryLabel.frame = NSRect(x: 0, y: 212, width: 98, height: 22)
        secondaryField.frame = NSRect(x: 110, y: 210, width: 210, height: 24)
        digitsLabel.frame = NSRect(x: 338, y: 212, width: 72, height: 22)
        digitsField.frame = NSRect(x: 420, y: 210, width: 100, height: 24)
        preserveExtension.frame = NSRect(x: 110, y: 174, width: 220, height: 22)
        validationText.frame = NSRect(x: 0, y: 142, width: 520, height: 26)
        previewText.frame = NSRect(x: 0, y: 0, width: 540, height: 132)
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshPreview()
    }

    func refreshPreview() {
        guard let rule = currentRule else {
            renderValidation(L10n.string(.FinderActions.renamePromptInvalidRenameRule), isValid: false)
            return
        }
        do {
            let plan = try FinderBatchRenamePlanner().makePlan(sourcePaths: sourcePaths, rule: rule)
            let changed = plan.changedItems
            let previewLines = changed.prefix(6).map {
                "\($0.sourceURL.lastPathComponent)  →  \($0.destinationURL.lastPathComponent)"
            }
            var text = previewLines.joined(separator: "\n")
            if changed.count > previewLines.count {
                text += L10n.string(.FinderActions.renamePromptPlusMore(String(describing: changed.count - previewLines.count)))
            }
            previewText.string = text
            renderValidation(L10n.string(.FinderActions.renamePromptItemsRenameNaturallySortedCurrent(String(describing: changed.count))), isValid: true)
        } catch {
            previewText.string = sourcePaths.prefix(6).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n")
            renderValidation(error.localizedDescription, isValid: false)
        }
    }

    @objc private func modeChanged() {
        guard let mode = FinderBatchRenameMode(rawValue: modePopup.selectedItem?.representedObject as? String ?? "") else { return }
        selectMode(mode)
    }

    @objc private func checkboxChanged() {
        refreshPreview()
    }

    private func configureViews() {
        let modeLabel = NSTextField(labelWithString: L10n.string(.FinderActions.renamePromptRenameMethod))
        modeLabel.frame = NSRect(x: 0, y: 290, width: 98, height: 22)
        modeLabel.alignment = .right
        addSubview(modeLabel)

        for mode in FinderBatchRenameMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
            modePopup.lastItem?.representedObject = mode.rawValue
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.setAccessibilityLabel(L10n.string(.FinderActions.renamePromptRenameMethod))
        addSubview(modePopup)

        for label in [primaryLabel, secondaryLabel, digitsLabel] {
            label.alignment = .right
            addSubview(label)
        }
        primaryField.delegate = self
        secondaryField.delegate = self
        digitsField.delegate = self
        primaryField.setAccessibilityLabel(L10n.string(.FinderActions.renamePromptPrimaryText))
        secondaryField.setAccessibilityLabel(L10n.string(.FinderActions.renamePromptReplacementTextStartingNumber))
        digitsField.setAccessibilityLabel(L10n.string(.FinderActions.renamePromptNumberWidth))
        addSubview(primaryField)
        addSubview(secondaryField)
        addSubview(digitsField)

        preserveExtension.state = .on
        preserveExtension.target = self
        preserveExtension.action = #selector(checkboxChanged)
        addSubview(preserveExtension)

        validationText.font = .systemFont(ofSize: 12)
        addSubview(validationText)

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = true
        previewText.backgroundColor = .controlBackgroundColor
        previewText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewText.textContainerInset = NSSize(width: 9, height: 8)
        previewText.setAccessibilityLabel(L10n.string(.FinderActions.renamePromptRenamePreview))
        previewText.wantsLayer = true
        previewText.layer?.cornerRadius = 7
        addSubview(previewText)
    }

    private func selectMode(_ mode: FinderBatchRenameMode) {
        if let index = FinderBatchRenameMode.allCases.firstIndex(of: mode) {
            modePopup.selectItem(at: index)
        }
        primaryField.stringValue = ""
        secondaryField.stringValue = mode == .sequence ? "1" : ""
        digitsField.stringValue = "2"
        digitsLabel.isHidden = mode != .sequence
        digitsField.isHidden = mode != .sequence

        switch mode {
        case .replace:
            primaryLabel.stringValue = L10n.string(.FinderActions.renamePromptFind)
            primaryField.placeholderString = L10n.string(.FinderActions.renamePromptTextReplace)
            secondaryLabel.stringValue = L10n.string(.FinderActions.renamePromptReplace)
            secondaryField.placeholderString = L10n.string(.FinderActions.renamePromptLeaveEmptyRemove)
            secondaryLabel.isHidden = false
            secondaryField.isHidden = false
        case .prefix:
            primaryLabel.stringValue = L10n.string(.FinderActions.renameAddPrefix)
            primaryField.placeholderString = L10n.string(.FinderActions.renamePromptExampleProject)
            secondaryLabel.isHidden = true
            secondaryField.isHidden = true
        case .suffix:
            primaryLabel.stringValue = L10n.string(.FinderActions.renameAddSuffix)
            primaryField.placeholderString = L10n.string(.FinderActions.renamePromptExampleArchive)
            secondaryLabel.isHidden = true
            secondaryField.isHidden = true
        case .sequence:
            primaryLabel.stringValue = L10n.string(.FinderActions.renamePromptBaseName)
            primaryField.placeholderString = L10n.string(.FinderActions.renamePromptExamplePhoto)
            secondaryLabel.stringValue = L10n.string(.FinderActions.renamePromptStartingNumber)
            secondaryLabel.isHidden = false
            secondaryField.isHidden = false
        }
        refreshPreview()
        window?.makeFirstResponder(primaryField)
    }

    private func renderValidation(_ message: String, isValid: Bool) {
        validationText.stringValue = message
        validationText.textColor = isValid ? .secondaryLabelColor : .systemOrange
        validationChanged?(isValid)
    }
}
