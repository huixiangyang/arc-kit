import ArcKitPlatform
import ArcKitFinder
@preconcurrency import AppKit
import SwiftUI

struct FinderDirectoriesEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let requestReset: () -> Void

    var body: some View {
        Section {
            HStack(spacing: 6) {
                ArcToolbarButton(title: L10n.string(.Common.add), symbol: .arcPlus, action: addDir)
                ArcToolbarButton(title: L10n.string(.FinderSettings.favoritesClearAll), symbol: .arcTrash, prominence: .destructive) {
                    requestReset()
                }
                .disabled(model.settings.menuConfiguration.favoriteDirectories.isEmpty)
                Spacer()
            }
            if model.settings.menuConfiguration.favoriteDirectories.isEmpty {
                Text(L10n.string(.FinderSettings.favoritesFavoriteFoldersYetMissing)).font(.caption).foregroundStyle(ArcPalette.secondaryText).frame(maxWidth: .infinity, minHeight: 48)
            }
            ForEach(Array(model.settings.menuConfiguration.favoriteDirectories.enumerated()), id: \.element.id) { index, _ in
                DirectoryRow(dir: directoryBinding(index),
                    canMoveUp: index > 0,
                    canMoveDown: index < model.settings.menuConfiguration.favoriteDirectories.count - 1,
                    moveUp: { moveDir(index: index, offset: -1) },
                    moveDown: { moveDir(index: index, offset: 1) },
                    remove: { removeDir(at: index) })
            }

        }
    }

    private func directoryBinding(_ i: Int) -> Binding<FavoriteDirectory> {
        let resource = model.settings.menuConfiguration.favoriteDirectories[i]
        return Binding(
            get: { model.settings.menuConfiguration.favoriteDirectories.first { $0.id == resource.id } ?? resource },
            set: { value in model.update(actionName: L10n.string(.FinderSettings.favoritesEditFavoriteFolder)) {
                guard let index = $0.menuConfiguration.favoriteDirectories.firstIndex(where: { $0.id == resource.id }) else { return }
                $0.menuConfiguration.favoriteDirectories[index] = value
            } }
        )
    }

    private func moveDir(index i: Int, offset: Int) {
        model.update(actionName: L10n.string(.FinderSettings.favoritesReorderFavoriteFolders)) {
            $0.menuConfiguration.moveFavoriteDirectoryInDisplayOrder(from: i, offset: offset)
        }
    }

    private func addDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = L10n.string(.Common.add)
        guard p.runModal() == .OK, let url = p.url else { return }
        let standardizedPath = (url.path as NSString).standardizingPath
        guard !model.settings.menuConfiguration.favoriteDirectories.contains(where: {
            ($0.path as NSString).standardizingPath == standardizedPath
        }) else {
            showFinderFavoriteAlert(title: L10n.string(.FinderSettings.favoritesFolderAlreadyAdded), message: L10n.string(.FinderSettings.favoritesAlreadyFavoriteFolders(String(describing: standardizedPath))))
            return
        }
        model.update(actionName: L10n.string(.FinderSettings.favoritesAddFavoriteFolder)) { $0.menuConfiguration.favoriteDirectories.append(
            FavoriteDirectory(name: url.lastPathComponent, path: standardizedPath, sortOrder: $0.menuConfiguration.favoriteDirectories.count)) }
    }

    private func removeDir(at i: Int) {
        model.update(actionName: L10n.string(.FinderSettings.favoritesRemoveFavoriteFolder)) { $0.menuConfiguration.favoriteDirectories.remove(at: i) }
    }

}

struct FinderApplicationsEditor: View {
    @ObservedObject var model: SettingsEditor<FinderRuntimeSettings>
    let requestReset: () -> Void

    var body: some View {
        Group {
            Section {
                HStack(spacing: 6) {
                    ArcToolbarButton(title: L10n.string(.Common.add), symbol: .arcPlus, action: addApp)
                    ArcToolbarButton(title: L10n.string(.FinderSettings.favoritesRestoreDefaultApps), symbol: .arcRefresh) {
                        requestReset()
                    }
                    .disabled(isDefaultApplicationConfiguration)
                    Spacer()
                    Text(L10n.string(.FinderSettings.appsInstalledCount(Int(availableApplicationEntries.count))))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.mutedText)
                }

                if availableApplicationEntries.isEmpty {
                    Text(L10n.string(.FinderSettings.favoritesAvailableAppsYetMissing)).font(.caption).foregroundStyle(ArcPalette.secondaryText).frame(maxWidth: .infinity, minHeight: 48)
                }

                ForEach(availableApplicationEntries, id: \.element.id) { index, _ in
                    AppRow(app: appBinding(index),
                        canMoveUp: index != availableApplicationEntries.first?.offset,
                        canMoveDown: index != availableApplicationEntries.last?.offset,
                        moveUp: { moveAvailableApp(index: index, offset: -1) },
                        moveDown: { moveAvailableApp(index: index, offset: 1) },
                        remove: { removeApp(at: index) })
                }

            }
            if !unavailableApplicationEntries.isEmpty {
                Section(L10n.string(.FinderSettings.favoritesAppsNotInstalled)) {
                    ForEach(unavailableApplicationEntries, id: \.element.id) { index, _ in
                        UnavailableAppRow(app: appBinding(index), remove: { removeApp(at: index) })
                    }
                }
            }
        }
    }

    private var availableApplicationEntries: [(offset: Int, element: FavoriteApplication)] {
        Array(model.settings.menuConfiguration.favoriteApplications.enumerated())
            .filter { $0.element.resolvedAppURL != nil }
    }

    private var unavailableApplicationEntries: [(offset: Int, element: FavoriteApplication)] {
        Array(model.settings.menuConfiguration.favoriteApplications.enumerated())
            .filter { $0.element.resolvedAppURL == nil }
    }

    private var isDefaultApplicationConfiguration: Bool {
        model.settings.menuConfiguration.favoriteApplications == FavoriteApplication.defaults
    }

    private func appBinding(_ i: Int) -> Binding<FavoriteApplication> {
        let resource = model.settings.menuConfiguration.favoriteApplications[i]
        return Binding(
            get: { model.settings.menuConfiguration.favoriteApplications.first { $0.id == resource.id } ?? resource },
            set: { value in model.update(actionName: L10n.string(.FinderSettings.favoritesEditFavoriteApp)) {
                guard let index = $0.menuConfiguration.favoriteApplications.firstIndex(where: { $0.id == resource.id }) else { return }
                $0.menuConfiguration.favoriteApplications[index] = value
            } }
        )
    }

    private func moveAvailableApp(index: Int, offset: Int) {
        let visibleIDs = Set(availableApplicationEntries.map(\.element.id))
        let sourceID = model.settings.menuConfiguration.favoriteApplications[index].id
        model.update(actionName: L10n.string(.FinderSettings.favoritesReorderFavoriteApps)) {
            $0.menuConfiguration.moveFavoriteApplicationInVisibleOrder(
                id: sourceID,
                offset: offset,
                visibleApplicationIDs: visibleIDs
            )
        }
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.allowedContentTypes = [.applicationBundle]
        p.prompt = L10n.string(.FinderSettings.favoritesChooseApp)
        guard p.runModal() == .OK, let url = p.url else { return }
        let b = Bundle(url: url)
        let bid = b?.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String
        let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent
        let standardizedPath = (url.path as NSString).standardizingPath
        guard !model.settings.menuConfiguration.favoriteApplications.contains(where: { app in
            (bid != nil && app.bundleIdentifier == bid)
                || app.appPath.map { ($0 as NSString).standardizingPath == standardizedPath } == true
        }) else {
            showFinderFavoriteAlert(title: L10n.string(.FinderSettings.favoritesAppAlreadyAdded), message: L10n.string(.FinderSettings.favoritesAlreadyFavoriteApps(String(describing: name))))
            return
        }
        model.update(actionName: L10n.string(.FinderSettings.favoritesAddFavoriteApp)) { $0.menuConfiguration.favoriteApplications.append(
            FavoriteApplication(displayName: name, bundleIdentifier: bid, appPath: standardizedPath, sortOrder: $0.menuConfiguration.favoriteApplications.count)) }
    }

    private func removeApp(at i: Int) {
        model.update(actionName: L10n.string(.FinderSettings.favoritesRemoveFavoriteApp)) { $0.menuConfiguration.favoriteApplications.remove(at: i) }
    }

}

private struct DirectoryRow: View {
    @Binding var dir: FavoriteDirectory
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void; let moveDown: () -> Void; let remove: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            ArcIcon(.folder, size: 13).foregroundStyle(ArcPalette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(dir.name).font(.subheadline).foregroundStyle(ArcPalette.primaryText)
                Text(dir.path).font(.caption).foregroundStyle(ArcPalette.mutedText).lineLimit(1).truncationMode(.middle)
                Picker(L10n.string(.FinderSettings.favoritesMenuContents), selection: $dir.displayMode) {
                    ForEach(FavoriteDirectoryDisplayMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }.controlSize(.small).fixedSize()
            }
            Spacer()
            Toggle("", isOn: $dir.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small).fixedSize()
                .accessibilityLabel(L10n.string(.FinderSettings.favoritesEnableFolder(String(describing: dir.name))))
            Menu(L10n.string(.FinderSettings.templatesActions)) {
                Button(L10n.string(.FinderSettings.templatesMoveUp), action: moveUp).disabled(!canMoveUp)
                Button(L10n.string(.FinderSettings.templatesMoveDown), action: moveDown).disabled(!canMoveDown)
                Divider()
                Button(L10n.string(.Common.remove), role: .destructive, action: remove)
            }
            .fixedSize()
            .accessibilityLabel(L10n.string(.FinderSettings.favoritesFolderActions(String(describing: dir.name))))
        }.padding(.horizontal, 10).padding(.vertical, 7)
        }
}

private struct AppRow: View {
    @Binding var app: FavoriteApplication
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void; let moveDown: () -> Void; let remove: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.localizedDisplayName).font(.subheadline).foregroundStyle(ArcPalette.primaryText)
                Text(app.enabled ? L10n.string(.FinderSettings.favoritesIncludedMenu) : L10n.string(.FinderSettings.favoritesDisabled))
                    .font(.caption2)
                    .foregroundStyle(ArcPalette.mutedText)
            }
            Spacer()
            Toggle(L10n.string(.FinderSettings.templatesShowTopLevel), isOn: $app.isPinnedToRootMenu)
                .toggleStyle(.checkbox).controlSize(.small)
            Toggle("", isOn: $app.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small).fixedSize()
                .accessibilityLabel(L10n.string(.FinderSettings.favoritesShowFinderMenu(String(describing: app.localizedDisplayName))))
            Menu(L10n.string(.FinderSettings.templatesActions)) {
                Button(L10n.string(.FinderSettings.templatesMoveUp), action: moveUp).disabled(!canMoveUp)
                Button(L10n.string(.FinderSettings.templatesMoveDown), action: moveDown).disabled(!canMoveDown)
                Divider()
                Button(L10n.string(.Common.remove), role: .destructive, action: remove)
            }
            .fixedSize()
            .accessibilityLabel(L10n.string(.FinderSettings.favoritesAppActions(String(describing: app.localizedDisplayName))))
        }.padding(.horizontal, 10).padding(.vertical, 7)
        }
}

private struct UnavailableAppRow: View {
    @Binding var app: FavoriteApplication
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.localizedDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(ArcPalette.primaryText)
                Text(app.enabled ? L10n.string(.FinderSettings.favoritesNotInstalledHint) : L10n.string(.FinderSettings.favoritesInstallDisabledHint))
                    .font(.caption2)
                    .foregroundStyle(ArcPalette.mutedText)
            }
            Spacer()
            Toggle(L10n.string(.FinderSettings.favoritesShowInstalled), isOn: $app.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(L10n.string(.FinderSettings.favoritesShowFinderMenuInstalled(String(describing: app.localizedDisplayName))))
            ArcIconActionButton(
                title: L10n.string(.FinderSettings.favoritesRemoveApp(String(describing: app.localizedDisplayName))),
                symbol: .trash2,
                emphasis: .destructive,
                action: remove
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

@MainActor
private func showFinderFavoriteAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.string(.DataManagement.transferGot))
    alert.runModal()
}
