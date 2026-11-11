import ArcKitPlatform
import AppKit
import SwiftUI

/// 小工具是一等导航入口；当前直接进入唯一工具，不放空的占位卡片。
enum ToolsFeature {
    static var entry: ApplicationFeatureEntry {
        .init(section: .tools, title: L10n.string(.Tools.title), icon: .wrench, commands: { [
            .command("section.tools", L10n.string(.Tools.inputTitle), L10n.string(.Tools.subtitle), .textCursorInput,
                L10n.string(.Tools.title), ["小工具", "输入法", "搜狗", "英文", "ABC", "input source", "keyboard", "Sogou"], .section(.tools), order: 65)
        ] })
    }
}

struct ToolsSection: View {
    @StateObject private var model: InputSourceToolModel
    init(isPreview: Bool) {
        #if DEBUG
        if isPreview { _model = StateObject(wrappedValue: InputSourceToolModel(access: InputSourcePreviewAccess())); return }
        #endif
        _model = StateObject(wrappedValue: InputSourceToolModel(access: NativeInputSourceAccess(
            recoveryURL: ArcKitStoragePaths.current.runtime.appendingPathComponent("input-source-recovery.plist"))))
    }
    var body: some View { InputSourceToolView(model: model) }
}

struct InputSourceToolView: View {
    @ObservedObject var model: InputSourceToolModel
    @State private var confirmsDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.configuration != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(L10n.string(.Tools.session)).foregroundStyle(.secondary)
                        Text(model.activeNames.isEmpty ? L10n.string(.Tools.sessionUnknown) : model.activeNames)
                            .fontWeight(.medium).textSelection(.enabled)
                    }.font(.system(size: 13))
                    editor
                }
                feedback
                if model.configuration != nil {
                    Text(L10n.string(.Tools.preservation))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .alert(L10n.string(.Tools.discardTitle), isPresented: $confirmsDiscard) {
            Button(L10n.string(.Common.cancel), role: .cancel) {}
            Button(L10n.string(.Tools.keepCurrent), role: .destructive) { model.discardRecovery() }
        } message: { Text(L10n.string(.Tools.discardHint)) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArcIcon(.textCursorInput, size: 24).foregroundStyle(ArcPalette.accent)
                .frame(width: 46, height: 46)
                .background(ArcPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(.Tools.inputTitle)).font(.system(size: 24, weight: .semibold))
                Text(L10n.string(.Tools.subtitle)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { model.refresh() } label: { ArcIcon(.refreshCw, size: 15) }
                .help(L10n.string(.Tools.refresh)).accessibilityLabel(L10n.string(.Tools.refresh))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(.Tools.configured))
                .font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(model.rows) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if model.recovery != nil {
                            ArcIcon(.checkCircle, size: 14).foregroundStyle(.secondary)
                            sourceLabel(record)
                        } else {
                            Toggle(isOn: Binding(
                                get: { model.selectedIDs.contains(record.selectionID) },
                                set: { model.setKept($0, record: record) }
                            )) {
                                sourceLabel(record)
                            }.toggleStyle(.checkbox)
                                .accessibilityIdentifier("tools.input-source.keep.\(record.selectionID)")
                        }
                        Spacer(minLength: 8)
                        if !model.selectedIDs.contains(record.selectionID) {
                            Text(L10n.string(.Tools.removed)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 11)
                    if record.id != model.rows.last?.id { Divider() }
                }
            }
            if model.recovery == nil {
                Text(L10n.string(.Tools.beforeApply)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.hasUsableSelection {
                    notice(L10n.string(.Tools.noTarget), icon: .triangleAlert, color: ArcPalette.orange)
                }
                Button { model.apply() } label: {
                    HStack(spacing: 8) {
                        ArcIcon(.checkCircle, size: 15)
                        Text(L10n.string(.Tools.apply))
                    }
                }.buttonStyle(.borderedProminent).tint(ArcPalette.accent).controlSize(.large).disabled(!model.canApply)
                    .accessibilityIdentifier("tools.input-source.apply")
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(ArcPalette.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ArcPalette.panelBorder.opacity(0.4)) }
    }

    private func sourceLabel(_ record: InputSourceRecord) -> some View {
        let state = model.sessionState(for: record)
        let status: LocalizedStringResource = switch state {
        case .enabled: .Tools.sessionEnabled
        case .disabled: .Tools.sessionDisabled
        case .unknown: .Tools.sessionUnconfirmed
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(model.name(for: record)).font(.system(size: 13))
            Text(L10n.string(status)).font(.system(size: 12))
                .foregroundStyle(state == .enabled ? ArcPalette.green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let failure = model.failure {
            notice(failure, icon: .triangleAlert, color: ArcPalette.red)
        }
        if model.recovery != nil {
            VStack(alignment: .leading, spacing: 12) {
                if !model.configurationMatchesRecovery {
                    notice(L10n.string(.Tools.configurationChanged), icon: .triangleAlert, color: ArcPalette.orange)
                    Button(L10n.string(.Tools.keepCurrent)) { confirmsDiscard = true }
                } else {
                    notice(model.applied ? L10n.string(.Tools.applied) : L10n.string(.Tools.pending),
                        icon: model.applied ? .checkCircle : .circleInfo, color: model.applied ? ArcPalette.green : ArcPalette.orange)
                }
                Button(L10n.string(.Tools.restore)) { model.restore() }
                    .disabled(!model.canRestore).accessibilityIdentifier("tools.input-source.restore")
            }
        } else if model.restored {
            notice(L10n.string(.Tools.restored), icon: .checkCircle, color: ArcPalette.green)
        }
    }

    private func notice(_ text: String, icon: ArcIconName, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ArcIcon(icon, size: 16).foregroundStyle(color)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
