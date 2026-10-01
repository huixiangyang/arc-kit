import ArcKitPlatform
import ArcKitWindow
import AppKit
import SwiftUI

struct ArcKitQuickFind: View {
    let execute: (ArcKitQuickCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedCommandID: String?
    @State private var screenCount = NSScreen.screens.count

    private var results: [ArcKitQuickCommand] {
        Array(ArcKitQuickCommandCatalog.results(for: query).prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ArcIcon(.search, size: 18)
                    .foregroundStyle(ArcPalette.mutedText)
                TextField(L10n.string(.App.searchSearchFeaturesSettingsWindowActions), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { executeSelectedCommand() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        ArcIcon(.circleX, size: 17)
                            .foregroundStyle(ArcPalette.mutedText)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .accessibilityLabel(L10n.string(.App.searchClearSearch))
                    .help(L10n.string(.App.searchClearSearch))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Divider().overlay(ArcPalette.divider)

            if results.isEmpty {
                VStack(spacing: 9) {
                    ArcIcon(.search, size: 24)
                        .foregroundStyle(ArcPalette.mutedText)
                    Text(L10n.string(.App.searchNoResults(String(describing: query))))
                        .font(.body.weight(.medium))
                    Text(L10n.string(.App.searchTryScreenshotShortcutLeftHalfUpdate))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 4) {
                            ForEach(results) { command in
                                commandRow(command)
                                    .id(command.id)
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selectedCommandID) { commandID in
                        guard let commandID else { return }
                        // 键盘选择必须把当前项带入视口，避免焦点落在不可见结果上。
                        proxy.scrollTo(commandID, anchor: .center)
                    }
                }
            }

            Divider().overlay(ArcPalette.divider)
            HStack {
                Text(query.isEmpty ? L10n.string(.App.searchQuickAccess) : L10n.string(.App.searchResultLimit))
                Spacer()
                Text(L10n.string(.App.searchReturnRunEscClose))
            }
            .font(.caption2)
            .foregroundStyle(ArcPalette.mutedText)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: 590, height: 470)
        .background(ArcPalette.background)
        .onAppear {
            selectedCommandID = preferredSelectionID
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _ in
            selectedCommandID = preferredSelectionID
        }
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenCount = NSScreen.screens.count
            if let selected = results.first(where: { $0.id == selectedCommandID }),
               commandUnavailableReason(selected) != nil {
                selectedCommandID = preferredSelectionID
            }
        }
    }

    private func commandRow(_ command: ArcKitQuickCommand) -> some View {
        let unavailableReason = commandUnavailableReason(command)
        return Button {
            guard unavailableReason == nil else { return }
            run(command)
        } label: {
            HStack(spacing: 13) {
                ArcIcon(command.symbol, size: 17)
                    .foregroundStyle(unavailableReason == nil ? ArcPalette.accent : ArcPalette.mutedText)
                    .frame(width: 32, height: 32)
                    .background(ArcPalette.panelSecondary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ArcPalette.primaryText)
                    Text(unavailableReason ?? command.detail)
                        .font(.caption)
                        .foregroundStyle(unavailableReason == nil ? ArcPalette.secondaryText : ArcPalette.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(command.category)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ArcPalette.mutedText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ArcPalette.panelSecondary, in: Capsule())
                ArcIcon(commandRunsImmediately(command) ? .cornerDownLeft : .chevronRight, size: 13)
                    .foregroundStyle(ArcPalette.mutedText)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(
                selectedCommandID == command.id ? ArcPalette.sidebarActive : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .onHover { hovering in
            if hovering { selectedCommandID = command.id }
        }
        .accessibilityLabel(command.title)
        .accessibilityHint(unavailableReason ?? (commandRunsImmediately(command) ? L10n.string(.App.searchRunWindowActionNow) : L10n.string(.App.searchOpenRelatedSettings)))
    }

    private func executeSelectedCommand() {
        guard let command = results.first(where: { $0.id == selectedCommandID }) ?? results.first,
              commandUnavailableReason(command) == nil
        else { return }
        run(command)
    }

    private func run(_ command: ArcKitQuickCommand) {
        dismiss()
        // 先关闭查找浮层，再执行导航或窗口动作，避免焦点仍停留在临时窗口。
        DispatchQueue.main.async { execute(command) }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        let currentIndex = results.firstIndex { $0.id == selectedCommandID } ?? 0
        switch direction {
        case .up:
            selectedCommandID = results[max(0, currentIndex - 1)].id
        case .down:
            selectedCommandID = results[min(results.count - 1, currentIndex + 1)].id
        default:
            break
        }
    }

    private func commandRunsImmediately(_ command: ArcKitQuickCommand) -> Bool {
        if case .window = command.action { return true }
        return false
    }

    private var preferredSelectionID: String? {
        results.first(where: { commandUnavailableReason($0) == nil })?.id ?? results.first?.id
    }

    private func commandUnavailableReason(_ command: ArcKitQuickCommand) -> String? {
        guard case let .window(action) = command.action else { return nil }
        return WindowActionAvailability.unavailableReason(action, screenCount: screenCount)
    }
}
