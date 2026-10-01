import ArcKitPlatform
import ArcKitWindow
@preconcurrency import AppKit
import SwiftUI

struct WindowRulesEditor: View {
    @ObservedObject var model: SettingsEditor<WindowManagementSettings>
    @ObservedObject var windowService: WindowManagementService
    @State private var appConfigurationCandidate: AppConfigurationCandidate?
    @State private var excludedApplicationNotice: String?

    var body: some View {
        Section(L10n.string(.WindowSettings.rulesAppExceptionsMultipleDisplays)) {
            advancedSettings
        }
        .onAppear { refreshAppConfigurationCandidate() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAppConfigurationCandidate()
        }
        .onChange(of: model.settings.excludedApplications) { _ in
            // 撤销、重做或外部重载后，提示必须服从当前排除列表事实。
            excludedApplicationNotice = nil
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(L10n.string(.WindowSettings.rulesDisplaySwitching))
                    .font(.subheadline)
                    .foregroundStyle(ArcPalette.primaryText)
                Spacer()
                Picker(L10n.string(.WindowSettings.rulesDisplaySwitching), selection: displayNavigationStrategyBinding) {
                    ForEach(WindowDisplayNavigationStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            Divider().overlay(ArcPalette.divider)

            HStack {
                Text(L10n.string(.WindowSettings.rulesExcludedApps)).font(.system(size: 13))
                Spacer()
                ArcToolbarButton(title: addCandidateButtonTitle, symbol: .arcPlus, action: addFrontmostApp)
                    .disabled(!canAddAppConfigurationCandidate)
                ArcToolbarButton(title: L10n.string(.MouseSettings.appsChooseApp), symbol: .arcFinder, action: chooseApp)
            }

            if model.settings.excludedApplications.isEmpty {
                Text(L10n.string(.WindowSettings.rulesExcludedAppsMissing))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.mutedText)
            } else {
                ForEach(model.settings.excludedApplications) { app in
                    HStack(spacing: 9) {
                        ArcIcon(.appWindow, size: 16)
                            .foregroundStyle(ArcPalette.mutedText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.displayName).font(.subheadline)
                            Text(app.bundleIdentifier).font(.caption).foregroundStyle(ArcPalette.mutedText)
                        }
                        Spacer()
                        Button(L10n.string(.Common.remove)) { removeExcludedApp(app) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(ArcPalette.red)
                    }
                    .frame(minHeight: 42)
                }
            }
            if let excludedApplicationNotice {
                Text(excludedApplicationNotice)
                    .font(.caption)
                    .foregroundStyle(ArcPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayNavigationStrategyBinding: Binding<WindowDisplayNavigationStrategy> {
        Binding(
            get: { model.settings.displayNavigationStrategy },
            set: { value in
                model.update(actionName: L10n.string(.WindowSettings.rulesChangeDisplaySwitchingOrder)) {
                    $0.displayNavigationStrategy = value
                }
            }
        )
    }

    private var addCandidateButtonTitle: String {
        guard let appConfigurationCandidate else { return L10n.string(.MouseSettings.appsAddRecentApp) }
        if model.settings.isExcluded(
            bundleIdentifier: appConfigurationCandidate.bundleIdentifier
        ) {
            return L10n.string(.WindowSettings.rulesExcluded(String(describing: appConfigurationCandidate.displayName)))
        }
        return L10n.string(.MouseSettings.appsAdd(String(describing: appConfigurationCandidate.displayName)))
    }

    private var canAddAppConfigurationCandidate: Bool {
        guard let appConfigurationCandidate else { return false }
        return !model.settings.isExcluded(
            bundleIdentifier: appConfigurationCandidate.bundleIdentifier
        )
    }

    private func refreshAppConfigurationCandidate() {
        appConfigurationCandidate = windowService.configurableApplicationCandidate()
    }

    private func addFrontmostApp() {
        guard let app = windowService.configurableApplicationCandidate() else {
            appConfigurationCandidate = nil
            windowService.reportFailure(L10n.string(.WindowSettings.rulesExternalAppAvailableAddSwitchMissing))
            return
        }
        appConfigurationCandidate = app
        appendExcludedApp(displayName: app.displayName, bundleIdentifier: app.bundleIdentifier)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.string(.Common.choose)
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier
        else { return }
        appendExcludedApp(displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, bundleIdentifier: bundleIdentifier)
    }

    private func appendExcludedApp(displayName: String, bundleIdentifier: String) {
        do {
            let application = try WindowExcludedApplication.excludedApplication(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                currentBundleIdentifier: Bundle.main.bundleIdentifier
            )
            var windowSettings = model.settings
            switch try windowSettings.addExcludedApplication(application) {
            case .inserted:
                model.update(actionName: L10n.string(.WindowSettings.rulesExcludeWindowManagement(String(describing: application.displayName)))) {
                    $0 = windowSettings
                }
                excludedApplicationNotice = nil
            case let .alreadyExists(existing):
                excludedApplicationNotice = L10n.string(.WindowSettings.rulesAlreadyExcludedExistingEntry(String(describing: existing.displayName)))
            }
        } catch {
            windowService.reportFailure(error.localizedDescription)
        }
    }

    private func removeExcludedApp(_ app: WindowExcludedApplication) {
        model.update(actionName: L10n.string(.WindowSettings.rulesRemoveExcludedWindowApp)) { settings in
            settings.excludedApplications.removeAll { $0.id == app.id }
        }
    }
}
