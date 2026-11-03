import ArcKitPlatform
import AppKit
import SwiftUI

/// 管理页直接承载真实清单；状态和恢复入口留在发生问题的位置，不再跳到搜索弹窗。
struct MenuBarManagementList: View {
    @ObservedObject var inventory: MenuBarShelfModel
    let canInteract: Bool
    let refresh: () -> Void
    let openPermission: () -> Void
    let activate: (UUID?) -> Void
    var usesSampleData = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArcIcon(.search, size: 16).foregroundStyle(.secondary)
                TextField(L10n.string(.MenuBar.managementSearch), text: $inventory.query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { if canInteract { activate(inventory.selectedID) } }
                if !inventory.query.isEmpty {
                    Button { inventory.query = "" } label: { ArcIcon(.circleX, size: 14) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.string(.MenuBar.managementClearSearch))
                }
                Button(action: refresh) {
                    HStack(spacing: 5) {
                        ArcIcon(.refreshCw, size: 13)
                        Text(L10n.string(.MenuBar.inventoryRefresh))
                    }
                }.buttonStyle(.borderless)
                    .disabled(!canInteract || inventory.isLoading || inventory.activeItemID != nil)
            }.padding(16)
            Divider()
            if let stale = inventory.staleReason, inventory.error == nil {
                HStack(alignment: .top, spacing: 8) {
                    ArcIcon(.circleInfo, size: 14)
                    Text(stale).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.foregroundStyle(ArcPalette.orange).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(ArcPalette.orange.opacity(0.06))
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(ArcPalette.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ArcPalette.panelBorder.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var content: some View {
        if inventory.isLoading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(L10n.string(.MenuBar.shelfLoading)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else if let error = inventory.error {
            placeholder(icon: inventory.permissionRequired ? .lockKeyhole : .triangleAlert,
                        title: L10n.string(inventory.permissionRequired ? .MenuBar.managementPermissionTitle : .MenuBar.managementReadFailed),
                        detail: inventory.permissionRequired ? L10n.string(.MenuBar.managementPermissionDetail) : error) {
                if inventory.permissionRequired {
                    Button(L10n.string(.MenuBar.settingsOpenPermission), action: openPermission)
                        .buttonStyle(.borderedProminent).tint(ArcPalette.orange).disabled(!canInteract)
                }
                Button(L10n.string(.MenuBar.managementReadAgain), action: refresh)
                    .buttonStyle(.bordered).disabled(!canInteract)
            }
        } else if inventory.items.isEmpty {
            placeholder(icon: .panelTop, title: L10n.string(.MenuBar.managementEmptyTitle),
                        detail: L10n.string(.MenuBar.managementEmptyDetail)) {
                Button(L10n.string(.MenuBar.managementReadAgain), action: refresh)
                    .buttonStyle(.bordered).disabled(!canInteract)
            }
        } else if inventory.filteredItems.isEmpty {
            placeholder(icon: .search, title: L10n.string(.MenuBar.managementNoMatches),
                        detail: L10n.string(.MenuBar.managementNoMatchesDetail)) {
                Button(L10n.string(.MenuBar.managementClearSearch)) { inventory.query = "" }.buttonStyle(.bordered)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(inventory.filteredItems) { item in
                            row(item).id(item.id)
                            Divider().padding(.leading, 58)
                        }
                    }.padding(.vertical, 5)
                }.onChange(of: inventory.scrollTarget) { id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if usesSampleData { Text(L10n.string(.MenuBar.managementSampleData)) }
            else if inventory.issueCount > 0 {
                ArcIcon(.circleInfo, size: 12)
                Text(L10n.string(.MenuBar.managementPartial))
            } else if let date = inventory.capturedAt {
                Text(L10n.string(.MenuBar.managementUpdated(L10n.time(date))))
            } else { Text(L10n.string(.MenuBar.managementReadOnlyDiscovery)) }
            Spacer(minLength: 8)
            if inventory.inventoryID != nil || !inventory.items.isEmpty {
                Text(L10n.string(.MenuBar.managementCount(String(inventory.filteredItems.count))))
                    .monospacedDigit()
            }
        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func row(_ item: MenuBarObservedItem) -> some View {
        HStack(spacing: 12) {
            MenuBarApplicationIcon(bundleIdentifier: item.bundleIdentifier).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let outcome = inventory.outcomes[item.id] {
                    switch outcome {
                    case .sent: EmptyView()
                    case .failed, .unconfirmed:
                        Text(outcome.detail).font(.system(size: 12)).foregroundStyle(ArcPalette.orange)
                            .lineLimit(2).help(outcome.detail)
                    }
                } else if let subtitle = item.label, !subtitle.isEmpty, subtitle != item.displayTitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help(subtitle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            rowAction(item).font(.system(size: 12)).frame(width: 90, alignment: .trailing)
        }.frame(minHeight: 58).padding(.horizontal, 16).padding(.vertical, 3)
            .background(inventory.selectedID == item.id ? ArcPalette.orange.opacity(0.055) : .clear)
            .contentShape(Rectangle()).onTapGesture { inventory.select(item.id) }
            .accessibilityElement(children: .contain)
            .help(item.bundleIdentifier ?? item.applicationName)
    }

    @ViewBuilder private func rowAction(_ item: MenuBarObservedItem) -> some View {
        if inventory.activeItemID == item.id {
            ProgressView().controlSize(.small).accessibilityLabel(L10n.string(.MenuBar.managementSending))
        } else if let outcome = inventory.outcomes[item.id] {
            switch outcome {
            case .sent:
                Text(L10n.string(.MenuBar.accessAccepted)).foregroundStyle(.secondary)
            case .unconfirmed:
                Text(L10n.string(.MenuBar.managementUnconfirmed)).foregroundStyle(ArcPalette.orange)
            case .failed:
                Text(L10n.string(.MenuBar.managementRefreshRequired)).foregroundStyle(ArcPalette.orange)
            }
        } else if !item.supportsActivation {
            Text(L10n.string(.MenuBar.managementViewOnly)).foregroundStyle(.secondary)
                .help(L10n.string(.MenuBar.accessUnsupported))
        } else {
            Button(L10n.string(item.declaresShowMenu ? .MenuBar.managementOpenMenu : .MenuBar.managementPress)) { activate(item.id) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!canInteract || !inventory.canActivate(item))
                .accessibilityLabel(L10n.string(.MenuBar.managementActivateItem(item.displayTitle)))
        }
    }

    private func placeholder<Actions: View>(icon: ArcIconName, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            ArcIcon(icon, size: 30).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions() }
                VStack(spacing: 10) { actions() }
            }.padding(.top, 4)
        }.frame(maxWidth: 340).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 应用图标沿用系统资源；读取图标不启动应用，缺失时用 Lucide 通用应用图标。
struct MenuBarApplicationIcon: View {
    let bundleIdentifier: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { ArcIcon(bundleIdentifier == "com.apple.MenuBarAgent" ? .panelTop : .appWindow, size: 24).foregroundStyle(.secondary) }
        }.accessibilityHidden(true).task(id: bundleIdentifier) {
            // 系统菜单代理没有面向用户的应用图标，不显示它的默认包占位图。
            guard let bundleIdentifier, bundleIdentifier != "com.apple.MenuBarAgent",
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                image = nil; return
            }
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
