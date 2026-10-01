import ArcKitPlatform
import ArcKitFinder
@preconcurrency import AppKit
import SwiftUI

struct FinderPreferencesEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    var body: some View {
        Group {
            observedDirectoriesPanel
        }
    }

    private var defaultObservedDirectories: [(name: String, path: String)] {
        let home = FinderUserHomeDirectoryResolver.resolve().path
        return FinderObservedDirectoryBuilder.defaultObservedDirectoryPaths().map { path in
            (path == home ? L10n.string(.FinderSettings.preferencesHomeFolder) : "iCloud Drive", path)
        }
    }

    /// Home 与可用的 iCloud Drive 默认注册；注册不等于系统会提供右键回调。
    private func addObservedDirectory() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.canCreateDirectories = false
        p.prompt = L10n.string(.FinderSettings.preferencesAddWorkFolder)
        p.message = L10n.string(.FinderSettings.preferencesAddLocalFolderSubfolders)
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = (url.path as NSString).standardizingPath
        let existing = model.settings.menuConfiguration.additionalObservedDirectoryPaths
        let home = (FinderUserHomeDirectoryResolver.resolve().path as NSString).standardizingPath

        guard FinderObservedDirectoryBuilder.isSafeObservedDirectoryPath(path) else {
            showConfigurationAlert(
                title: L10n.string(.FinderSettings.preferencesAddFolderFailed),
                message: L10n.string(.FinderSettings.preferencesProtectedDirectoryHint)
            )
            return
        }
        guard path != home, !path.hasPrefix("\(home)/") else {
            showConfigurationAlert(title: L10n.string(.FinderSettings.preferencesAlreadyIncluded), message: L10n.string(.FinderSettings.preferencesHomeFolderIcloudDrive))
            return
        }
        guard !existing.contains(path) else {
            showConfigurationAlert(title: L10n.string(.FinderSettings.preferencesFolderAlreadyAdded), message: L10n.string(.FinderSettings.preferencesExternalFolderAlreadyIncluded))
            return
        }

        model.update(actionName: L10n.string(.FinderSettings.preferencesAddFinderMenuFolder)) {
            $0.menuConfiguration.additionalObservedDirectoryPaths.append(path)
        }
    }

    private func removeObservedDirectory(at index: Int) {
        model.update(actionName: L10n.string(.FinderSettings.preferencesRemoveFinderMenuFolder)) {
            $0.menuConfiguration.additionalObservedDirectoryPaths.remove(at: index)
        }
    }

    private var observedDirectoriesPanel: some View {
        Section(L10n.string(.FinderSettings.preferencesWatchedFolders)) {
            ForEach(defaultObservedDirectories, id: \.path) { directory in
                observedDirectoryRow(name: directory.name, path: directory.path, isDefault: true)
            }

            ForEach(externalAdditionalObservedDirectories, id: \.path) { directory in
                observedDirectoryRow(name: L10n.string(.FinderSettings.preferencesExternalFolders), path: directory.path, isDefault: false) {
                    let index = directory.index
                    removeObservedDirectory(at: index)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Button(action: addObservedDirectory) {
                    Label {
                        Text(L10n.string(.FinderSettings.preferencesAddExternalFolder))
                    } icon: {
                        ArcIcon(.hardDriveUpload, size: 14)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint(L10n.string(.FinderSettings.preferencesAddRegularFolderOutsideHome))
                .help(L10n.string(.FinderSettings.preferencesHomeIcloudDriveRegisteredAdd))
                Spacer(minLength: 0)
            }
        }
    }

    private var externalAdditionalObservedDirectories: [(index: Int, path: String)] {
        let home = (FinderUserHomeDirectoryResolver.resolve().path as NSString).standardizingPath
        return model.settings.menuConfiguration.additionalObservedDirectoryPaths
            .enumerated()
            .compactMap { index, rawPath in
                let path = (rawPath as NSString).standardizingPath
                guard path != home, !path.hasPrefix("\(home)/") else { return nil }
                return (index, path)
            }
    }

    private func observedDirectoryRow(
        name: String,
        path: String,
        isDefault: Bool,
        remove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            ArcIcon(isDefault ? .folderOpen : .folder, size: 16)
                .foregroundStyle(isDefault ? ArcPalette.accent : ArcPalette.secondaryText)
                .frame(width: 18)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(ArcPalette.primaryText)
                .frame(width: 86, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(ArcPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if path == FinderObservedDirectoryBuilder.iCloudDriveDirectory().path {
                Text(L10n.string(.FinderSettings.preferencesToolbarMenu))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.secondaryText)
                    .help(L10n.string(.FinderSettings.preferencesClickArcKitFinderToolbar))
            } else if isDefault {
                Text(L10n.string(.FinderSettings.preferencesDefault))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.mutedText)
            } else if let remove {
                Button(L10n.string(.Common.remove), role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.string(.FinderSettings.preferencesRemoveWatchedFolder(String(describing: path))))
            }
        }
    }

    private func showConfigurationAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string(.DataManagement.transferGot))
        alert.runModal()
    }

}

struct FinderTerminalEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    var body: some View {
        Picker(L10n.string(.FinderSettings.preferencesDefaultTerminal), selection: Binding(
            get: { model.settings.defaultTerminal },
            set: { value in model.update(actionName: L10n.string(.FinderSettings.preferencesChooseTerminal)) { $0.defaultTerminal = value } }
        )) {
            ForEach(TerminalApp.allCases, id: \.self) { terminal in
                Text(terminal.displayName).tag(terminal)
                    .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) == nil)
            }
        }
        .help(L10n.string(.FinderSettings.preferencesUsedTopLevel))
    }
}

struct FinderRiskEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    @State private var showsHighRiskConfirmation = false

    var body: some View {
        Toggle(L10n.string(.FinderSettings.preferencesAllowHighRiskActions), isOn: Binding(
            get: { model.settings.menuConfiguration.highRiskActionsEnabled },
            set: { enabled in
                if enabled { showsHighRiskConfirmation = true }
                else { model.update(actionName: L10n.string(.FinderSettings.preferencesDisableHighRiskFinderActions)) { $0.menuConfiguration.highRiskActionsEnabled = false } }
            }
        ))
        .help(L10n.string(.FinderSettings.preferencesOffDefaultPermanentDeletionHidingOther))
        .confirmationDialog(L10n.string(.FinderSettings.preferencesHighRiskConfirmation), isPresented: $showsHighRiskConfirmation, titleVisibility: .visible) {
            Button(L10n.string(.FinderSettings.preferencesEnableAnyway), role: .destructive) {
                model.update(actionName: L10n.string(.FinderSettings.preferencesEnableHighRiskFinderActions)) { $0.menuConfiguration.highRiskActionsEnabled = true }
            }
            Button(L10n.string(.Common.cancel), role: .cancel) {}
        } message: {
            Text(L10n.string(.FinderSettings.preferencesPermanentDeletionHint))
        }
    }
}
