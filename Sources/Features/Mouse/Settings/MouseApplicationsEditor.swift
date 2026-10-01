import ArcKitPlatform
import ArcKitMouse
@preconcurrency import AppKit
import SwiftUI

struct MouseApplicationsEditor: View {
    @ObservedObject var model: SettingsEditor<MouseEnhancementSettings>
    @ObservedObject var mouseService: MouseScrollEnhancementService
    let applicationCandidate: () -> MouseApplicationCandidate?
    @State private var profileModifierAssignmentNotices: [UUID: String] = [:]
    @State private var appProfileNotice: String?
    @State private var appConfigurationCandidate: MouseApplicationCandidate?

    var body: some View {
        Group {
            Section(L10n.string(.MouseSettings.appsUnlistedApplications)) {
                Picker(L10n.string(.MouseSettings.appsScrollingMode), selection: Binding(
                    get: { model.settings.scrollScope },
                    set: { value in
                        model.update(actionName: L10n.string(.MouseSettings.appsChangeScrollEnhancementScope)) {
                            $0.scrollScope = value
                        }
                    }
                )) {
                    Text(MouseAppScrollBehavior.inherit.title).tag(MouseScrollScope.allApplications)
                    Text(MouseAppScrollBehavior.system.title).tag(MouseScrollScope.selectedApplications)
                }
                if model.settings.isEnabled,
                   model.settings.scrollScope == .selectedApplications,
                   model.settings.enabledAppProfileCount == 0 {
                    Text(L10n.string(.MouseSettings.appsNoEnhancedApplications))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.secondaryText)
                }
            }

            Section(L10n.string(.MouseSettings.appsIndividualSettings)) {
                HStack(spacing: 8) {
                    ArcToolbarButton(title: L10n.string(.MouseSettings.appsAddApplication), symbol: .arcPlus, action: addApplicationProfile)
                    if let candidate = appConfigurationCandidate,
                       !model.settings.appProfiles.contains(where: { $0.bundleIdentifier == candidate.bundleIdentifier }) {
                        ArcToolbarButton(title: L10n.string(.MouseSettings.appsAdd(String(describing: candidate.displayName))), symbol: .arcPlus) {
                            // 使用按钮显示的应用，点击时不重新捕获并悄悄换成另一个目标。
                            appendProfile(displayName: candidate.displayName, bundleIdentifier: candidate.bundleIdentifier)
                        }
                    }
                    Spacer()
                }
                if model.settings.appProfiles.isEmpty {
                    Text(L10n.string(.MouseSettings.appsNoIndividualSettings))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.secondaryText)
                }
                ForEach(model.settings.appProfiles) { profile in
                    appProfileRow(profile: profile)
                }
                if let appProfileNotice {
                    MouseEditorFeedback(text: appProfileNotice, verticalPadding: 8)
                }
            }
        }
        .onAppear {
            appConfigurationCandidate = applicationCandidate()
            reconcileProfilePresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appConfigurationCandidate = applicationCandidate()
        }
        .onChange(of: model.settings.appProfiles) { _ in
            reconcileProfilePresentation()
        }
    }

    private func reconcileProfilePresentation() {
        let currentIDs = Set(model.settings.appProfiles.map(\.id))
        profileModifierAssignmentNotices = profileModifierAssignmentNotices.filter { currentIDs.contains($0.key) }
        appProfileNotice = nil
    }

    private func appProfileRow(profile: MouseAppScrollProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MouseRuleApplicationLabel(profile: profile)
                Spacer(minLength: 8)
                // 行内选择器直接属于左侧应用，避免把应用规则误读成第二个全局开关。
                Picker(L10n.string(.MouseSettings.appsModeForApplication(profile.displayName)), selection: profileBehaviorBinding(id: profile.id)) {
                    ForEach(MouseAppScrollBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Button { removeProfile(id: profile.id) } label: {
                    ArcIcon(.trash2, size: 14)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string(.MouseSettings.appsRemoveApplicationRule(profile.displayName)))
                .help(model.settings.scrollScope == .allApplications
                      ? L10n.string(.MouseSettings.appsRemoveUsesDefaults)
                      : L10n.string(.MouseSettings.appsRemoveDisablesEnhancement))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.string(.MouseSettings.appsNote))
                    .foregroundStyle(ArcPalette.secondaryText)
                TextField(L10n.string(.MouseSettings.appsNote), text: profileNoteBinding(id: profile.id),
                          prompt: Text(L10n.string(.MouseSettings.appsNoteOptional)), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .lineLimit(1...3)
                    .accessibilityLabel(L10n.string(.MouseSettings.appsNoteForApplication(profile.displayName)))
            }
            if profile.behavior == .custom {
                Divider()
                customTuning(profile: profile)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func customTuning(profile: MouseAppScrollProfile) -> some View {
        VStack(spacing: 10) {
            Toggle(L10n.string(.MouseSettings.scrollSmoothScrolling), isOn: profileTuningBoolBinding(id: profile.id, \.smoothEnabled, actionName: L10n.string(.MouseSettings.appsToggleAppSmoothScrolling))
            )
            .help(L10n.string(.MouseSettings.appsOverridesScrollingFeelApp))
            Toggle(L10n.string(.MouseSettings.appsReverseVerticalScrolling), isOn: profileTuningBoolBinding(id: profile.id, \.reverseVertical, actionName: L10n.string(.MouseSettings.appsToggleAppScrollDirection))
            )
            .help(L10n.string(.MouseSettings.appsOverridesAppWithoutChangingGlobalSettings))
            MouseSliderRow(title: L10n.string(.MouseSettings.appsScrollStep), value: profileTuningDoubleBinding(id: profile.id, \.stepLength), range: 16...120, suffix: "px")
            MouseSliderRow(title: L10n.string(.MouseSettings.scrollScrollSpeed), value: profileTuningDoubleBinding(id: profile.id, \.speedGain), range: 0.5...3.0, suffix: "×")
            MouseSliderRow(title: L10n.string(.MouseSettings.scrollSmoothingDuration), value: profileTuningIntBinding(id: profile.id, \.responseTimeMs), range: 80...320, suffix: "ms")
                .disabled(!profile.tuning.smoothEnabled)
            MouseSliderRow(title: L10n.string(.MouseSettings.scrollAccelerationMultiplier), value: profileTuningDoubleBinding(id: profile.id, \.accelerationMultiplier), range: 1.5...6.0, suffix: "×")
                .disabled(profile.tuning.accelerationModifier == .none)
            MouseModifierPicker(title: L10n.string(.MouseSettings.tuningHorizontalScrolling), selection: profileTuningModifierBinding(id: profile.id, role: .horizontalScroll))
            MouseModifierPicker(title: L10n.string(.MouseSettings.appsAcceleratedScrolling), selection: profileTuningModifierBinding(id: profile.id, role: .acceleratedScroll))
            MouseModifierPicker(title: L10n.string(.MouseSettings.appsDisableSmoothing), selection: profileTuningModifierBinding(id: profile.id, role: .disableSmoothScroll))
                .disabled(!profile.tuning.smoothEnabled)
            if !profile.tuning.smoothEnabled {
                Text(L10n.string(.MouseSettings.appsEnableSmoothScrollingApp))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = profileModifierAssignmentNotices[profile.id] {
                MouseEditorFeedback(text: notice)
            }
            HStack(spacing: 8) {
                ArcToolbarButton(title: L10n.string(.MouseSettings.appsCopyGlobalValues), symbol: .arcRefresh, action: { resetProfileTuningToGlobal(id: profile.id) })
                Spacer()
            }
        }
    }

    private func profileNoteBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { model.settings.appProfiles.first(where: { $0.id == id })?.note ?? "" },
            set: { value in
                model.update(actionName: L10n.string(.MouseSettings.appsChangeNote), coalescingKey: "mouse-profile-\(id)-note") {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    $0.appProfiles[index].note = value
                }
            }
        )
    }

    private func profileBehaviorBinding(id: UUID) -> Binding<MouseAppScrollBehavior> {
        Binding(
            get: { model.settings.appProfiles.first(where: { $0.id == id })?.behavior ?? .inherit },
            set: { value in
                model.update(actionName: L10n.string(.MouseSettings.appsChangeAppScrollingMode)) {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    // 从继承切到自定义，以当前全局手感作为起点。
                    if value == .custom, $0.appProfiles[index].behavior == .inherit {
                        $0.appProfiles[index].tuning = $0.globalTuning
                    }
                    $0.appProfiles[index].behavior = value
                }
            }
        )
    }

    private func profileTuningBoolBinding(
        id: UUID,
        _ keyPath: WritableKeyPath<MouseScrollTuning, Bool>,
        actionName: String
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings.appProfiles.first(where: { $0.id == id })?.tuning[keyPath: keyPath] ?? false },
            set: { value in
                model.update(actionName: actionName) {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    $0.appProfiles[index].tuning[keyPath: keyPath] = value
                }
            }
        )
    }

    private func profileTuningDoubleBinding(id: UUID, _ keyPath: WritableKeyPath<MouseScrollTuning, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings.appProfiles.first(where: { $0.id == id })?.tuning[keyPath: keyPath] ?? 0 },
            set: { value in
                model.update(
                    actionName: L10n.string(.MouseSettings.appsAdjustAppScrollingFeel),
                    coalescingKey: "mouse-profile-\(id)-\(String(describing: keyPath))"
                ) {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    $0.appProfiles[index].tuning[keyPath: keyPath] = value
                }
            }
        )
    }

    private func profileTuningIntBinding(id: UUID, _ keyPath: WritableKeyPath<MouseScrollTuning, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.appProfiles.first(where: { $0.id == id })?.tuning[keyPath: keyPath] ?? 0) },
            set: { value in
                model.update(
                    actionName: L10n.string(.MouseSettings.appsAdjustAppScrollingFeel),
                    coalescingKey: "mouse-profile-\(id)-\(String(describing: keyPath))"
                ) {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    $0.appProfiles[index].tuning[keyPath: keyPath] = Int(value.rounded())
                }
            }
        )
    }

    private func profileTuningModifierBinding(id: UUID, role: MouseScrollModifierRole) -> Binding<MouseModifierGesture> {
        Binding(
            get: { model.settings.appProfiles.first(where: { $0.id == id })?.tuning.modifier(for: role) ?? .none },
            set: { value in
                guard let profile = model.settings.appProfiles.first(where: { $0.id == id }) else { return }
                var tuning = profile.tuning
                let clearedRoles = tuning.assignModifier(value, to: role)
                model.update(actionName: L10n.string(.MouseSettings.appsSetAppModifier(String(describing: role.displayName)))) {
                    guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
                    $0.appProfiles[index].tuning = tuning
                }
                profileModifierAssignmentNotices[profile.id] = MouseEditorFeedback.modifierReassignmentNotice(
                    modifier: value,
                    role: role,
                    clearedRoles: clearedRoles
                )
            }
        )
    }

    private func resetProfileTuningToGlobal(id: UUID) {
        let profileID = model.settings.appProfiles.first(where: { $0.id == id })?.id
        model.update(actionName: L10n.string(.MouseSettings.appsRestoreAppScrollingFeel)) {
            guard let index = $0.appProfiles.firstIndex(where: { $0.id == id }) else { return }
            $0.appProfiles[index].tuning = $0.globalTuning
        }
        if let profileID {
            profileModifierAssignmentNotices[profileID] = nil
        }
    }

    private func addApplicationProfile() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string(.MouseSettings.appsChooseApp)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        appendProfile(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    private func appendProfile(displayName: String, bundleIdentifier: String?) {
        do {
            let profile = try MouseAppScrollProfile.appProfile(
                displayName: displayName,
                bundleIdentifier: bundleIdentifier,
                tuning: model.settings.globalTuning,
                currentBundleIdentifier: Bundle.main.bundleIdentifier
            )
            appendProfileIfMissing(profile)
        } catch {
            mouseService.reportConfigurationFailure(error.localizedDescription)
        }
    }

    private func appendProfileIfMissing(_ profile: MouseAppScrollProfile) {
        var mouseSettings = model.settings
        do {
            switch try mouseSettings.addAppProfile(profile) {
            case .inserted:
                model.update(actionName: L10n.string(.MouseSettings.appsAddMouseSettings(String(describing: profile.displayName)))) {
                    $0 = mouseSettings
                }
                appProfileNotice = nil
            case let .alreadyExists(existing):
                appProfileNotice = L10n.string(.MouseSettings.appsAlreadyListedSettingsUnchanged(String(describing: existing.displayName)))
            }
        } catch {
            mouseService.reportConfigurationFailure(error.localizedDescription)
        }
    }

    private func removeProfile(id: UUID) {
        guard let profile = model.settings.appProfiles.first(where: { $0.id == id }) else { return }
        model.update(actionName: L10n.string(.MouseSettings.appsRemoveAppMouseSettings)) {
            $0.removeAppProfile(id: profile.id)
        }
        profileModifierAssignmentNotices[profile.id] = nil
    }

}

/// 应用身份使用系统应用图标；技术标识只保留为悬停信息。
private struct MouseRuleApplicationLabel: View {
    let profile: MouseAppScrollProfile
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    ArcIcon(.squareDashed, size: 18)
                        .foregroundStyle(ArcPalette.secondaryText)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            Text(profile.displayName)
                .lineLimit(1)
                .help(profile.bundleIdentifier ?? profile.displayName)
        }
        .task(id: profile.bundleIdentifier) {
            guard let identifier = profile.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                icon = nil
                return
            }
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

/// 添加规则时使用界面显示的应用，不触发窗口选择或应用激活。
struct MouseApplicationCandidate {
    let displayName: String
    let bundleIdentifier: String
}
