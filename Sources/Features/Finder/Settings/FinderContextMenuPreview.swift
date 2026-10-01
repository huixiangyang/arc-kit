import ArcKitPlatform
import ArcKitFinder
import SwiftUI

/// 按需打开的 Finder 菜单预览，与实际扩展共用菜单树。
struct FinderContextMenuPreview: View {
    let settings: FinderRuntimeSettings
    let isDraft: Bool
    @State private var selectedTarget: PreviewTarget = .blank
    @State private var menuTreeState: FinderMenuTreeState?
    @StateObject private var icons = FinderMenuIcons()

    init(settings: FinderRuntimeSettings, isDraft: Bool) {
        self.settings = settings
        self.isDraft = isDraft
        // 首帧等待可用性解析；不先展示尚未验证的应用和目录。
        _menuTreeState = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                ArcIcon(.arcFinder, size: 13)
                    .foregroundStyle(ArcPalette.accent)
                Text(L10n.string(.FinderSettings.previewContextMenuPreview))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcPalette.secondaryText)
                Spacer()
                Text(isDraft ? L10n.string(.FinderSettings.previewUnsaved) : L10n.string(.FinderSettings.previewSavedConfiguration))
                    .font(.caption2)
                    .foregroundStyle(ArcPalette.mutedText)
            }
            .padding(.horizontal, 14)
            // 与左侧工作区的首行对齐，同时避开窗口标题栏区域。
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker(L10n.string(.FinderSettings.previewPreviewSelection), selection: $selectedTarget) {
                ForEach(PreviewTarget.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if !settings.menuConfiguration.isEnabled {
                VStack(spacing: 8) {
                    ArcIcon(.arcFinder, size: 20)
                        .foregroundStyle(ArcPalette.mutedText)
                    Text(L10n.string(.FinderSettings.previewFinderContextMenuOff))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if menuTreeState == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 菜单列表：填满剩余空间，内容过多内部滚动
                let rows = rootRows()

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            Text(L10n.string(.FinderSettings.previewMenuItemsSelectionMissing)).font(.caption).foregroundStyle(ArcPalette.mutedText).padding(18)
                        }
                        ForEach(rows) { row in
                            if row.isSeparator {
                                separatorLine
                            } else {
                                mainRow(row: row)

                                if !row.children.isEmpty {
                                    subRows(for: row)
                                        .padding(.leading, 20)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }
            Text(L10n.string(.FinderSettings.previewLayoutPreviewCheckActualMenu))
                .font(.caption2).foregroundStyle(ArcPalette.mutedText).padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ArcPalette.panelSecondary.opacity(0.48))
        .task(id: settings) {
            menuTreeState = nil
            // 设置编辑可能连续发布多帧，先合并短时间变化，避免并发扫描外置目录。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let resolvedState = await Task.detached(priority: .utility) {
                Self.makeMenuTreeState(settings: settings)
            }.value
            guard !Task.isCancelled else { return }
            icons.prepare(for: resolvedState)
            menuTreeState = resolvedState
        }
    }
}

// MARK: - Sub-views

private extension FinderContextMenuPreview {
    enum PreviewTarget: String, CaseIterable, Identifiable {
        case blank
        case file
        case folder
        case image
        case multipleFolders
        case mixed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .blank: L10n.string(.FinderSettings.previewEmptyArea)
            case .file: L10n.string(.FinderSettings.previewFile)
            case .folder: L10n.string(.FinderSettings.previewFolder)
            case .image: L10n.string(.AppBackground.backgroundStorageImage)
            case .multipleFolders: L10n.string(.FinderSettings.previewFolders)
            case .mixed: L10n.string(.FinderSettings.previewMixedSelection)
            }
        }

        var context: FinderMenuTargetContext {
            switch self {
            case .blank:
                FinderMenuTargetContext(kind: .blank)
            case .file:
                FinderMenuTargetContext(kind: .files, selectedItemCount: 1)
            case .folder:
                FinderMenuTargetContext(kind: .folders, selectedItemCount: 1)
            case .image:
                FinderMenuTargetContext(kind: .images, selectedItemCount: 1)
            case .multipleFolders:
                FinderMenuTargetContext(kind: .folders, selectedItemCount: 2)
            case .mixed:
                FinderMenuTargetContext(kind: .mixed, selectedItemCount: 2)
            }
        }
    }

    var separatorLine: some View {
        Rectangle()
            .fill(ArcPalette.divider.opacity(0.5))
            .frame(height: 1)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
    }

    func mainRow(row: PreviewRootRow) -> some View {
        HStack(spacing: 8) {
            previewIcon(row.entry)
            Text(row.title)
                .font(.subheadline)
                .foregroundStyle(ArcPalette.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func subRows(for row: PreviewRootRow) -> some View {
        ForEach(row.childRows) { child in
            previewText(child.entry, level: child.level)
        }
    }

    func previewText(_ entry: FinderMenuEntry, level: Int) -> some View {
        HStack(spacing: 8) {
            previewIcon(entry)
            Text(entry.title)
                .font(.caption)
                .foregroundStyle(level == 0 ? ArcPalette.secondaryText : ArcPalette.mutedText)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(level) * 10)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    func previewIcon(_ entry: FinderMenuEntry) -> some View {
        if let image = icons.image(for: entry) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
                .foregroundStyle(ArcPalette.secondaryText)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Grouping

private extension FinderContextMenuPreview {
    struct PreviewRootRow: Identifiable {
        let id: String
        let entry: FinderMenuEntry
        let title: String
        let moduleID: FinderMenuModuleID?
        let children: [FinderMenuEntry]
        let childRows: [PreviewChildRow]
        let isSeparator: Bool
    }

    struct PreviewChildRow: Identifiable {
        let id: String
        let entry: FinderMenuEntry
        let level: Int
    }

    func rootRows() -> [PreviewRootRow] {
        guard let menuTreeState else { return [] }
        let entries = FinderMenuTreeBuilder.buildEntries(
            state: menuTreeState,
            context: selectedTarget.context
        )
        return entries.map { entry in
            switch entry {
            case let .action(descriptor):
                return PreviewRootRow(
                    id: descriptor.actionID,
                    entry: entry,
                    title: descriptor.title,
                    moduleID: descriptor.moduleID,
                    children: [],
                    childRows: [],
                    isSeparator: false
                )
            case let .submenu(id, title, moduleID, _, children):
                return PreviewRootRow(
                    id: id,
                    entry: entry,
                    title: title,
                    moduleID: moduleID,
                    children: children,
                    childRows: flattenChildren(children),
                    isSeparator: false
                )
            case let .separator(id):
                return PreviewRootRow(
                    id: id,
                    entry: entry,
                    title: "",
                    moduleID: nil,
                    children: [],
                    childRows: [],
                    isSeparator: true
                )
            }
        }
    }

    func flattenChildren(_ entries: [FinderMenuEntry], level: Int = 0) -> [PreviewChildRow] {
        entries.flatMap { entry -> [PreviewChildRow] in
            switch entry {
            case let .action(descriptor):
                return [PreviewChildRow(id: descriptor.actionID, entry: entry, level: level)]
            case let .submenu(id, _, _, _, children):
                return [PreviewChildRow(id: id, entry: entry, level: level)] + flattenChildren(children, level: level + 1)
            case .separator:
                return []
            }
        }
    }

    nonisolated static func makeMenuTreeState(settings: FinderRuntimeSettings) -> FinderMenuTreeState {
        let snapshot = FinderExtensionSnapshot.make(
            settings: settings,
            applicationAvailability: { FavoriteApplicationAvailabilityResolver.isAvailable($0) }
        )
        return FinderMenuTreeState(snapshot: snapshot)
    }

}
