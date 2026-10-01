import ArcKitPlatform
import ArcKitFinder
@preconcurrency import AppKit
import SwiftUI

struct FinderTemplatesEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let templateLibrary: NewFileTemplateLibrary
    let requestReset: () -> Void

    var body: some View {
        Section {
            Toggle(L10n.string(.FinderSettings.templatesOpenDefaultAppCreation), isOn: Binding(
                get: { model.settings.menuConfiguration.openNewFileAfterCreate },
                set: { value in model.update(actionName: L10n.string(.FinderSettings.templatesChangeOpeningBehaviorNewFiles)) { $0.menuConfiguration.openNewFileAfterCreate = value } }
            )).toggleStyle(.switch).controlSize(.small)
            HStack(spacing: 6) {
                ArcToolbarButton(title: L10n.string(.FinderSettings.templatesChooseTemplateFile), symbol: .arcPlus, action: addTemplateFromFile)
                ArcToolbarButton(title: L10n.string(.FinderSettings.templatesRestoreDefaultTemplates), symbol: .arcRefresh) {
                    requestReset()
                }
                .disabled(isDefaultTemplateConfiguration)
                Spacer()
            }
            ForEach(Array(model.settings.menuConfiguration.fileTemplates.enumerated()), id: \.element.id) { index, _ in
                TemplateRow(template: templateBinding(index),
                    canMoveUp: index > 0,
                    canMoveDown: index < model.settings.menuConfiguration.fileTemplates.count - 1,
                    moveUp: { moveTemplate(index: index, offset: -1) },
                    moveDown: { moveTemplate(index: index, offset: 1) },
                    remove: { removeTemplate(at: index) })
            }

        }
    }

    private var isDefaultTemplateConfiguration: Bool {
        model.settings.menuConfiguration.fileTemplates == ConfigurableNewFileTemplate.defaults
    }

    private func templateBinding(_ i: Int) -> Binding<ConfigurableNewFileTemplate> {
        let template = model.settings.menuConfiguration.fileTemplates[i]
        // 编辑弹层存活期间列表可能被撤销或重排，始终按身份写回。
        return Binding(
            get: { model.settings.menuConfiguration.fileTemplates.first { $0.id == template.id } ?? template },
            set: { value in model.update(actionName: L10n.string(.FinderSettings.templatesEditFileTemplate)) {
                guard let index = $0.menuConfiguration.fileTemplates.firstIndex(where: { $0.id == template.id }) else { return }
                $0.menuConfiguration.fileTemplates[index] = value
            } }
        )
    }

    private func moveTemplate(index i: Int, offset: Int) {
        model.update(actionName: L10n.string(.FinderSettings.templatesReorderFileTemplates)) {
            $0.menuConfiguration.moveTemplateInDisplayOrder(from: i, offset: offset)
        }
    }

    private func addTemplateFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string(.FinderSettings.templatesChooseTemplate)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let template = try templateLibrary.importTemplate(
                from: url,
                sortOrder: model.settings.menuConfiguration.fileTemplates.count
            )
            model.update(actionName: L10n.string(.FinderSettings.templatesAddFileTemplate)) {
                $0.menuConfiguration.fileTemplates.append(template)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func removeTemplate(at i: Int) {
        model.update(actionName: L10n.string(.FinderSettings.templatesRemoveFileTemplate)) { $0.menuConfiguration.fileTemplates.remove(at: i) }
    }
}

private struct TemplateRow: View {
    @Binding var template: ConfigurableNewFileTemplate
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void; let moveDown: () -> Void; let remove: () -> Void
    @State private var showEditor = false
    @State private var editName = ""

    var body: some View {
        HStack(spacing: 10) {
            NewFileTemplateIconView(template: template, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(template.localizedDisplayName).font(.subheadline).foregroundStyle(ArcPalette.primaryText)
                Text(".\(template.normalizedExtension) · \(sourceLabel)").font(.caption).foregroundStyle(ArcPalette.mutedText)
                if let reason = template.unsupportedReason {
                    Text(reason).font(.caption2).foregroundStyle(ArcPalette.orange)
                }
            }
            Spacer()
            Toggle(L10n.string(.FinderSettings.templatesShowTopLevel), isOn: $template.isPinnedToRootMenu)
                .toggleStyle(.checkbox).controlSize(.small)
                .help(L10n.string(.FinderSettings.templatesShowTopLevelFinder))
            Toggle("", isOn: Binding(
                get: { template.enabled && template.isFinderNewFileSupported },
                set: { template.enabled = template.isFinderNewFileSupported ? $0 : false }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!template.isFinderNewFileSupported)
            .accessibilityLabel(L10n.string(.FinderSettings.templatesEnableTemplate(String(describing: template.localizedDisplayName))))
            Menu(L10n.string(.FinderSettings.templatesActions)) {
                Button(L10n.string(.FinderSettings.templatesRename)) {
                    editName = template.displayName
                    showEditor = true
                }
                Button(L10n.string(.FinderSettings.templatesMoveUp), action: moveUp).disabled(!canMoveUp)
                Button(L10n.string(.FinderSettings.templatesMoveDown), action: moveDown).disabled(!canMoveDown)
                Divider()
                Button(L10n.string(.Common.remove), role: .destructive, action: remove)
            }
            .fixedSize()
            .accessibilityLabel(L10n.string(.FinderSettings.templatesTemplateActions(String(describing: template.localizedDisplayName))))
        }
        .popover(isPresented: $showEditor) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string(.FinderSettings.templatesEditTemplate)).font(.headline).foregroundStyle(ArcPalette.primaryText)
                TextField(L10n.string(.Common.name), text: $editName).textFieldStyle(.roundedBorder)
                LabeledContent(L10n.string(.FinderSettings.templatesFileType), value: ".\(template.normalizedExtension)")
                    .font(.caption)
                Text(L10n.string(.FinderSettings.templatesFileTypeComesTemplate))
                    .font(.caption2)
                    .foregroundStyle(ArcPalette.mutedText)
                if let nameValidationMessage {
                    Label {
                        Text(nameValidationMessage)
                    } icon: {
                        ArcIcon(.triangleAlert, size: 12)
                    }
                        .font(.caption)
                        .foregroundStyle(ArcPalette.red)
                }
                Text(sourceDetail).font(.caption).foregroundStyle(ArcPalette.secondaryText)
                HStack {
                    Button(L10n.string(.Common.cancel)) { showEditor = false }
                    Spacer()
                    Button(L10n.string(.Common.save)) {
                        template.displayName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        showEditor = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameValidationMessage != nil)
                }
            }
            .padding(16).frame(width: 320)
        }
    }

    private var nameValidationMessage: String? {
        let value = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return L10n.string(.FinderSettings.templatesNameEmpty) }
        if value.count > 40 { return L10n.string(.FinderSettings.templatesNameTooLong) }
        if value.contains("\n") || value.contains("\r") { return L10n.string(.FinderSettings.templatesNameLineBreak) }
        return nil
    }

    private var sourceLabel: String {
        switch template.resolvedTemplateSource {
        case .builtInResource:
            L10n.string(.FinderSettings.templatesBuiltTemplate)
        case .managedUserFile:
            L10n.string(.FinderSettings.templatesCustomTemplate)
        case nil:
            L10n.string(.FinderSettings.templatesMissingTemplate)
        }
    }

    private var sourceDetail: String {
        switch template.resolvedTemplateSource {
        case let .builtInResource(resourceName):
            L10n.string(.FinderSettings.templatesSourceBuiltTemplateFile(String(describing: resourceName)))
        case let .managedUserFile(path):
            L10n.string(.FinderSettings.templatesSourceStoredArcKitTemplate(String(describing: path)))
        case nil:
            L10n.string(.FinderSettings.templatesSourceTemplateFileConfiguredRemoveMissing)
        }
    }
}
