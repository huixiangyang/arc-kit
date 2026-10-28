import ArcKitPlatform
import SwiftUI

enum MenuBarWorkspaceTab: String, CaseIterable, Identifiable {
    case organize, appearance, behavior
    var id: Self { self }
    var title: String {
        switch self {
        case .organize: L10n.string(.MenuBar.pageOrganize)
        case .appearance: L10n.string(.MenuBar.pageAppearance)
        case .behavior: L10n.string(.MenuBar.pageBehavior)
        }
    }
}

struct MenuBarSection: View {
    @ObservedObject var model: SettingsEditor<MenuBarSettings>
    @ObservedObject var service: MenuBarManagementService
    @Binding var selectedTab: MenuBarWorkspaceTab
    @State private var showsNotch = true
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle(L10n.string(model.settings.isEnabled ? .Common.enabled : .Common.disabled), isOn: binding(\.isEnabled))
                    .toggleStyle(.switch).fixedSize().accessibilityLabel(L10n.string(.MenuBar.settingsEnable))
                Picker(L10n.string(.MenuBar.pageTitle), selection: $selectedTab) {
                    ForEach(MenuBarWorkspaceTab.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if service.isPreview {
                        notice(L10n.string(.MenuBar.settingsPreview), icon: .eye)
                    } else {
                        notice(L10n.string(.MenuBar.settingsExperimental), icon: .circleInfo)
                    }
                    if let message = service.message { notice(message, icon: .triangleAlert) }
                    if let status = service.environmentState.status { notice(status, icon: .circleInfo) }
                    if let receipt = service.lastActionReceipt { notice(receipt, icon: .circleInfo) }
                    switch selectedTab {
                    case .organize: organize
                    case .appearance: appearance
                    case .behavior: behavior
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.appBackgroundSurface()
        }
    }

    private var organize: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.string(.MenuBar.organizeTitle)).font(.system(size: 25, weight: .semibold))
                Text(L10n.string(service.partitionMode.supportsSections ? .MenuBar.organizeDetail : .MenuBar.overflowDescription))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if service.partitionMode.supportsSections {
                    zone(.eyeOff, .MenuBar.groupDeep, .MenuBar.groupDeepDetail, enabled: model.settings.deepSectionEnabled)
                }
                zone(.archive, service.partitionMode.supportsSections ? .MenuBar.groupHidden : .MenuBar.overflowTitle,
                     service.partitionMode.supportsSections ? .MenuBar.groupHiddenDetail : .MenuBar.overflowZoneDetail)
                zone(.eye, .MenuBar.groupVisible, .MenuBar.groupVisibleDetail)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string(service.partitionMode.supportsSections ? .MenuBar.organizeNativeDrag : .MenuBar.overflowArrange))
                    .font(.system(size: 13))
                if service.partitionMode.supportsSections {
                    Toggle(L10n.string(.MenuBar.settingsDeepSection), isOn: binding(\.deepSectionEnabled))
                        .toggleStyle(.switch).controlSize(.small)
                } else {
                    Text(L10n.string(.MenuBar.overflowSectionsUnavailable)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(service.partitionMode.presentations) { state in
                        Button(state.title) { service.present(state) }.buttonStyle(.bordered)
                            .disabled(state != .all && service.environmentState != .ready)
                    }
                }.disabled(service.isPreview || !service.isEnabled || model.hasUncommittedChanges)
                if service.isEnabled && !service.isPreview {
                    Text(L10n.string(.MenuBar.runtimeRequested(service.requestedPresentation.title)))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(L10n.string(.MenuBar.organizeRecovery)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                if service.partitionMode.supportsSections {
                    Button(L10n.string(.MenuBar.scopeOpenCollected)) { service.toggleShelf(scope: .collected) }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.isPreview || !service.isEnabled || model.hasUncommittedChanges || service.environmentState != .ready)
                }
                Button(L10n.string(.MenuBar.shelfOpen)) { service.toggleShelf(scope: .all) }
                    .disabled(service.isPreview || !service.isEnabled || model.hasUncommittedChanges || service.environmentState == .sleeping)
            }
            Divider()
            HStack {
                Text(L10n.string(.MenuBar.inventoryTitle)).font(.system(size: 15, weight: .semibold))
                Spacer()
                if service.isInspecting { ProgressView().controlSize(.small) }
                Button(L10n.string(.MenuBar.inventoryRefresh), action: service.refreshInventory)
                    .disabled(service.isPreview || service.isInspecting || service.environmentState == .sleeping)
            }
            if let inventory = service.inventory {
                if inventory.accessibility == .denied {
                    Text(L10n.string(.MenuBar.settingsMainPermission)).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button(L10n.string(.MenuBar.settingsOpenPermission), action: service.openAccessibilitySettings)
                } else {
                    TextField(L10n.string(.MenuBar.inventorySearch), text: $search).textFieldStyle(.roundedBorder)
                    if !inventory.issues.isEmpty {
                        Text(L10n.string(.MenuBar.inventoryIssues(String(inventory.issues.count))))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(inventory.items.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }.filter { search.isEmpty || $0.applicationName.localizedCaseInsensitiveContains(search) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false) }) { item in
                        HStack(spacing: 10) {
                            ArcIcon(.appWindow, size: 16).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.applicationName).font(.system(size: 13, weight: .medium))
                                Text(item.accessibilityIdentifier ?? item.bundleIdentifier ?? String(item.processID))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if service.partitionMode.supportsSections {
                                Text(sectionTitle(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            } else {
                Text(L10n.string(service.isPreview ? .MenuBar.inventoryPreview : .MenuBar.inventoryOnDemand)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var behavior: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.string(.MenuBar.hotKeyTitle)).font(.system(size: 24, weight: .semibold))
            Text(L10n.string(.MenuBar.hotKeyDescription)).font(.system(size: 13)).foregroundStyle(.secondary)
            shortcutPicker(.MenuBar.shelfOpen, keyPath: \.shelfShortcut, other: model.settings.revealShortcut)
            shortcutPicker(.MenuBar.actionShowAll, keyPath: \.revealShortcut, other: model.settings.shelfShortcut)
            if service.isPreview {
                notice(L10n.string(.MenuBar.hotKeyPreview), icon: .command)
            } else if model.hasUncommittedChanges {
                notice(L10n.string(.MenuBar.hotKeyPending), icon: .command)
            } else if !service.hotKeyFailures.isEmpty {
                ForEach([MenuBarHotKeyAction.shelf, .reveal], id: \.self) { action in
                    if let code = service.hotKeyFailures[action] {
                        notice(L10n.string(.MenuBar.hotKeyFailure(
                            L10n.string(action == .shelf ? .MenuBar.shelfOpen : .MenuBar.actionShowAll), String(code))), icon: .triangleAlert)
                    }
                }
                Button(L10n.string(.MenuBar.hotKeyRetry), action: service.retryHotKeys)
            } else if service.isEnabled && (model.settings.shelfShortcut != .disabled || model.settings.revealShortcut != .disabled) {
                notice(L10n.string(.MenuBar.hotKeyRegistered), icon: .checkCircle)
            }
            Divider()
            Text(L10n.string(.MenuBar.shelfBehaviorTitle)).font(.system(size: 16, weight: .semibold))
            Text(L10n.string(.MenuBar.shelfBehaviorDetail)).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(L10n.string(.MenuBar.shelfActionBoundary)).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func shortcutPicker(_ title: LocalizedStringResource, keyPath: WritableKeyPath<MenuBarSettings, MenuBarShortcutPreset>, other: MenuBarShortcutPreset) -> some View {
        Picker(L10n.string(title), selection: Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            model.update(actionName: L10n.string(.MenuBar.hotKeyEdit)) { $0[keyPath: keyPath] = value }
        })) {
            ForEach(MenuBarShortcutPreset.allCases) { value in
                Text(value.title).tag(value).disabled(value != .disabled && value == other)
            }
        }.pickerStyle(.menu)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            MenuBarScenePreview(style: model.settings.style, opacity: model.settings.opacity,
                showsNotch: showsNotch, cornerRadius: model.settings.cornerRadius)
                .frame(height: 216).clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 8) {
                ForEach(MenuBarAppearanceStyle.allCases) { style in
                    Button { model.update(actionName: L10n.string(.MenuBar.settingsEditAppearance)) { $0.style = style } } label: {
                        VStack(spacing: 7) {
                            ArcIcon(style == .split ? .panelsTopLeft : .panelTop, size: 20)
                            Text(style.title).font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                            .foregroundStyle(model.settings.style == style ? Color.white : Color.primary)
                            .background(model.settings.style == style ? ArcPalette.orange : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.settings.style == style ? .isSelected : [])
                }
            }
            VStack(spacing: 14) {
                HStack {
                    Text(L10n.string(.MenuBar.previewOpacity)).frame(width: 90, alignment: .leading)
                    Slider(value: numberBinding(\.opacity, key: "menu-bar-opacity"), in: 0.3...1)
                    Text(model.settings.opacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 45)
                }
                HStack {
                    Text(L10n.string(.MenuBar.settingsCornerRadius)).frame(width: 90, alignment: .leading)
                    Slider(value: numberBinding(\.cornerRadius, key: "menu-bar-radius"), in: 0...16, step: 1)
                    Text("\(Int(model.settings.cornerRadius)) pt").monospacedDigit().frame(width: 45)
                }
            }.font(.system(size: 13)).disabled(model.settings.style == .native)
            Toggle(L10n.string(.MenuBar.previewNotch), isOn: $showsNotch).toggleStyle(.switch).controlSize(.small)
            notice(L10n.string(.MenuBar.settingsAppearancePreviewOnly), icon: .paintbrush)
            Button(L10n.string(.MenuBar.settingsResetAppearance)) {
                model.update(actionName: L10n.string(.MenuBar.settingsResetAppearance)) {
                    $0.style = MenuBarSettings.defaults.style
                    $0.opacity = MenuBarSettings.defaults.opacity
                    $0.cornerRadius = MenuBarSettings.defaults.cornerRadius
                }
            }
        }
    }

    private func sectionTitle(_ item: MenuBarObservedItem) -> String {
        guard let partition = service.inventoryPartition else {
            return L10n.string(.MenuBar.scopeUnknown)
        }
        switch partition.section(of: item) {
        case .visible: return L10n.string(.MenuBar.groupVisible)
        case .collected: return L10n.string(.MenuBar.groupHidden)
        case .deep: return L10n.string(.MenuBar.groupDeep)
        case .unknown: return L10n.string(.MenuBar.scopeUnknown)
        case .otherDisplay: return L10n.string(.MenuBar.scopeOtherDisplay)
        }
    }

    private func zone(_ icon: ArcIconName, _ title: LocalizedStringResource, _ detail: LocalizedStringResource, enabled: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ArcIcon(icon, size: 20).foregroundStyle(enabled ? ArcPalette.orange : .secondary)
            Text(L10n.string(title)).font(.system(size: 13, weight: .semibold))
            Text(L10n.string(detail)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading).padding(14)
            .background(Color.primary.opacity(enabled ? 0.04 : 0.02), in: RoundedRectangle(cornerRadius: 10))
    }
    private func notice(_ title: String, icon: ArcIconName) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ArcIcon(icon, size: 15).foregroundStyle(ArcPalette.orange)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
    private func binding(_ keyPath: WritableKeyPath<MenuBarSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            model.update(actionName: L10n.string(.MenuBar.settingsEditManagement)) { $0[keyPath: keyPath] = value }
        })
    }
    private func numberBinding(_ keyPath: WritableKeyPath<MenuBarSettings, Double>, key: String) -> Binding<Double> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            model.update(actionName: L10n.string(.MenuBar.settingsEditAppearance), coalescingKey: key) { $0[keyPath: keyPath] = value }
        })
    }
}
