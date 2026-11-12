import ArcKitPlatform
import SwiftUI
import UniformTypeIdentifiers

/// 拖放只携带一次性令牌；原生位置键留在本进程，不接受外部文本或迟到的旧拖放。
@MainActor
private final class MenuBarArrangementDrag: ObservableObject {
    private var token: String?
    private var itemID: String?
    var isActive: Bool { token != nil }

    func begin(_ id: String) -> NSItemProvider {
        let value = UUID().uuidString
        token = value; itemID = id
        return NSItemProvider(object: value as NSString)
    }

    func receive(_ providers: [NSItemProvider], model: MenuBarArrangementModel, zone: MenuBarArrangementZone, before: String? = nil) -> Bool {
        guard model.canEdit, model.query.isEmpty, let token, let itemID, itemID != before,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { [weak self, weak model] object, _ in
            let received = (object as? NSString).map(String.init)
            Task { @MainActor in
                guard let self, let model, self.token == token, received == token, model.canEdit, model.query.isEmpty else { return }
                model.move(itemID, to: zone, before: before)
                self.token = nil; self.itemID = nil
            }
        }
        return true
    }
}

struct MenuBarArrangementView: View {
    @ObservedObject var model: MenuBarArrangementModel
    let refresh: () -> Void
    let apply: () -> Void
    let openPermission: () -> Void
    @StateObject private var drag = MenuBarArrangementDrag()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArcIcon(.search, size: 15).foregroundStyle(.secondary)
                TextField(L10n.string(.MenuBar.managementSearch), text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                Button(L10n.string(model.hasChanges ? .MenuBar.arrangeDiscardReload : .MenuBar.inventoryRefresh), action: refresh)
                    .buttonStyle(.borderless).disabled(model.isLoading || model.isApplying)
            }.padding(16)
            Divider()
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.string(.MenuBar.arrangeReading)).font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = model.error {
                            HStack(alignment: .top, spacing: 9) {
                                ArcIcon(.triangleAlert, size: 15).foregroundStyle(ArcPalette.orange)
                                Text(error).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }.padding(12).background(ArcPalette.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            if model.permissionRequired {
                                Button(L10n.string(.MenuBar.settingsOpenPermission), action: openPermission).buttonStyle(.borderless)
                            }
                        }
                        if !model.items.isEmpty {
                            Text(L10n.string(.MenuBar.arrangeApplicationScope))
                                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 16) {
                                    zone(.collected).frame(minWidth: 285)
                                    zone(.resident).frame(minWidth: 285)
                                }
                                VStack(spacing: 16) {
                                    // 首次选择时先露出可操作的应用，不让空收纳框占满窄窗口；草稿变化不颠倒分区。
                                    if model.isChoosingFirstCollection { zone(.resident); zone(.collected) }
                                    else { zone(.collected); zone(.resident) }
                                }
                            }
                            if !model.readOnlyItems.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L10n.string(.MenuBar.arrangeReadOnly)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                                    ForEach(model.readOnlyItems) { item in
                                        HStack(spacing: 10) {
                                            MenuBarApplicationIcon(bundleIdentifier: item.observed.bundleIdentifier).frame(width: 20, height: 20)
                                            Text(item.observed.displayTitle).font(.system(size: 13))
                                            Spacer()
                                            Text(item.restrictionText).font(.system(size: 12)).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(.horizontal, 2)
                            }
                        }
                    }.padding(16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                if model.isApplying {
                    ProgressView().controlSize(.small)
                    Text(L10n.string(.MenuBar.arrangeApplying)).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let feedback = model.feedback {
                    ArcIcon(.checkCircle, size: 14).foregroundStyle(ArcPalette.orange)
                    Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text(L10n.string(model.hasChanges ? .MenuBar.arrangePending : (model.query.isEmpty ? .MenuBar.arrangeDragHint : .MenuBar.arrangeSearchHint)))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if model.hasChanges {
                    Button(L10n.string(.MenuBar.arrangeDiscard), action: model.discard).buttonStyle(.borderless).disabled(model.isApplying)
                } else if model.canUndo {
                    Button(L10n.string(.MenuBar.arrangeUndo), action: model.undoLastApply).buttonStyle(.borderless).disabled(model.isApplying)
                }
                Button(L10n.string(.MenuBar.arrangeApply), action: apply)
                    .buttonStyle(.borderedProminent).tint(ArcPalette.orange).disabled(!model.canApply)
            }.padding(16)
        }
        .background(ArcPalette.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ArcPalette.panelBorder.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func zone(_ zone: MenuBarArrangementZone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ArcIcon(zone == .collected ? .archive : .eye, size: 16)
                Text(zone.title).font(.system(size: 14, weight: .semibold))
                Text(String(model.draft[zone].count)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(L10n.string(.MenuBar.arrangeLeftToRight)).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            if model.rows(zone).isEmpty {
                Text(L10n.string(.MenuBar.arrangeDropHere)).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ForEach(model.rows(zone)) { item in
                    MenuBarArrangementRow(item: item, zone: zone, model: model, drag: drag)
                    if item.id != model.rows(zone).last?.id { Divider().padding(.leading, 42) }
                }
            }
            Color.clear.frame(height: 14).contentShape(Rectangle())
        }
        .background(ArcPalette.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ArcPalette.panelBorder.opacity(0.6), lineWidth: 1))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            ArcKitLog.append("menu-bar arrangement drop-zone source=\(drag.isActive)")
            return drag.receive(providers, model: model, zone: zone)
        }
    }
}

private struct MenuBarArrangementRow: View {
    let item: MenuBarArrangementItem
    let zone: MenuBarArrangementZone
    @ObservedObject var model: MenuBarArrangementModel
    let drag: MenuBarArrangementDrag
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 9) {
            ArcIcon(.menu, size: 12).foregroundStyle(.tertiary)
            MenuBarApplicationIcon(bundleIdentifier: item.observed.bundleIdentifier).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.observed.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let label = item.observed.label, !label.isEmpty, label != item.observed.displayTitle {
                    Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let restriction = item.collectionRestriction {
                    Text(restriction.message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.setZone(item.id, to: zone == .collected ? .resident : .collected)
            } label: {
                ArcIcon(zone == .collected ? .eye : .archive, size: 14)
                    .frame(width: 24, height: 24)
            }.buttonStyle(.borderless).disabled(!model.canEdit || (zone == .resident && item.collectionRestriction != nil))
                .help(L10n.string(zone == .collected ? .MenuBar.arrangeMakeResident : .MenuBar.arrangeCollect))
                .accessibilityLabel(L10n.string(zone == .collected ? .MenuBar.arrangeResidentItem(item.actionTitle) : .MenuBar.arrangeCollectItem(item.actionTitle)))
        }.padding(.horizontal, 10).padding(.vertical, 10).frame(minHeight: 54)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { if isDropTarget { Rectangle().fill(ArcPalette.orange).frame(height: 2) } }
            .opacity(model.canEdit ? 1 : 0.55)
            .onDrag {
                ArcKitLog.append("menu-bar arrangement drag-begin editable=\(model.canEdit) filtered=\(!model.query.isEmpty)")
                guard model.canEdit, model.query.isEmpty else { return NSItemProvider() }
                return drag.begin(item.id)
            }
            .onDrop(of: [UTType.text], isTargeted: $isDropTarget) { providers in
                ArcKitLog.append("menu-bar arrangement drop-row source=\(drag.isActive)")
                return drag.receive(providers, model: model, zone: zone, before: item.id)
            }
            .contextMenu {
                Button(L10n.string(.MenuBar.arrangeMoveLeft)) { model.shift(item.id, in: zone, by: -1) }
                    .disabled(!model.canEdit || model.draft[zone].first == item.id)
                Button(L10n.string(.MenuBar.arrangeMoveRight)) { model.shift(item.id, in: zone, by: 1) }
                    .disabled(!model.canEdit || model.draft[zone].last == item.id)
            }
            .help(item.observed.bundleIdentifier == MenuBarInputMenu.bundleIdentifier ? L10n.string(.MenuBar.inputMenuScope) :
                (item.observed.bundleIdentifier ?? item.observed.applicationName))
    }
}
