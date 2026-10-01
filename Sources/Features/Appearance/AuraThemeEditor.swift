import ArcKitPlatform
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AuraThemeEditor: View {
    @ObservedObject var model: AppBackgroundModel
    @Environment(\.colorScheme) private var scheme
    @State private var advanced = false
    @State private var paletteDark = false
    @State private var naming = false
    @State private var name = ""
    @State private var importing = false
    @State private var importingImage = false
    @State private var exporting = false
    @State private var exportDocument: AuraExportDocument?
    @State private var deleting: String?
    @State private var selectionDate = Date()
    private var dark: Bool { scheme == .dark }
    private var selected: AuraTheme { model.settings.aura.resolved(in: model.settings.themes, at: selectionDate, dark: dark) }
    private var allThemes: [AuraTheme] { AuraTheme.builtins + model.settings.themes }

    var body: some View {
        Group {
            Section {
                grid(AuraTheme.builtins)
                if !model.settings.themes.isEmpty {
                    Text(L10n.string(.AppBackground.auraPersonal)).font(.subheadline).foregroundStyle(.secondary)
                    grid(model.settings.themes.sorted {
                        let a = model.settings.aura.favorites.contains($0.id), b = model.settings.aura.favorites.contains($1.id)
                        return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    })
                }
                HStack {
                    Button(L10n.string(.AppBackground.auraImport)) { importing = true }
                    Button(L10n.string(.AppBackground.auraExport)) {
                        do { exportDocument = try AuraExportDocument(theme: selected); exporting = true }
                        catch { model.showImportError(error) }
                    }
                    Spacer()
                    Button(L10n.string(.AppBackground.auraSave)) { name = selected.title; naming = true }
                }.controlSize(.small)
            } header: { Text(L10n.string(.AppBackground.auraThemes)) }

            Section {
                slider(L10n.string(.AppBackground.auraIntensity), binding(\.opacity), 0.05...1)
                slider(L10n.string(.AppBackground.auraOverlay), binding(\.dimming), 0...0.85)
                Picker(L10n.string(.AppBackground.auraMotion), selection: themeBinding(\.motion)) {
                    ForEach(AuraMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                DisclosureGroup(isExpanded: $advanced) {
                    Picker(L10n.string(.AppBackground.auraForm), selection: themeBinding(\.form)) {
                        ForEach(AuraForm.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    paletteEditor
                    slider(L10n.string(.AppBackground.auraSpread), themeBinding(\.spread), 0.5...1.5)
                    slider(L10n.string(.AppBackground.auraHorizontal), themeBinding(\.x), -0.4...0.4)
                    slider(L10n.string(.AppBackground.auraVertical), themeBinding(\.y), -0.4...0.4)
                    HStack {
                        Button(L10n.string(.AppBackground.auraShuffle)) { model.editTheme(dark: dark) { $0.seed = Int.random(in: 0...999_999) } }
                        Spacer()
                        Button(L10n.string(.AppBackground.auraExtract)) { importingImage = true }
                    }
                    slider(L10n.string(.AppBackground.auraParticles), themeBinding(\.particles), 0...1)
                    slider(L10n.string(.AppBackground.auraGrain), themeBinding(\.grain), 0...1)
                    Toggle(L10n.string(.AppBackground.auraParallax), isOn: binding(\.aura.parallax))
                } label: { Text(L10n.string(.AppBackground.auraAdvanced)) }
                HStack {
                    Button(L10n.string(.AppBackground.auraRestore)) { model.restoreTheme(dark: dark) }
                    Spacer()
                    Button(L10n.string(.AppBackground.auraUndo)) { model.undoAdjustment() }.disabled(model.undoSettings == nil)
                }.controlSize(.small)
            } header: { Text(L10n.string(.AppBackground.backgroundAppearanceAdjustments)) }
              footer: { Text(L10n.string(.AppBackground.auraHint)) }

            Section {
                Picker(L10n.string(.AppBackground.auraAutomation), selection: Binding(
                    get: { model.settings.aura.automation },
                    set: { value in model.update { $0.aura.automation = value; $0.aura.manualOverride = false } }
                )) {
                    ForEach(AuraAutomation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.settings.aura.automation != .manual {
                    themePicker(L10n.string(.AppBackground.auraDay), binding(\.aura.dayThemeID))
                    themePicker(L10n.string(.AppBackground.auraNight), binding(\.aura.nightThemeID))
                    if model.settings.aura.automation == .schedule {
                        DatePicker(L10n.string(.AppBackground.auraDayStart), selection: timeBinding(\.aura.dayStart), displayedComponents: .hourAndMinute)
                        DatePicker(L10n.string(.AppBackground.auraNightStart), selection: timeBinding(\.aura.nightStart), displayedComponents: .hourAndMinute)
                    }
                    if model.settings.aura.manualOverride {
                        Text(L10n.string(.AppBackground.auraOverride)).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.string(.AppBackground.auraResume)) { model.update { $0.aura.manualOverride = false } }
                    }
                }
            } header: { Text(L10n.string(.AppBackground.auraAutomation)) }
              footer: { if model.settings.aura.automation != .manual { Text(L10n.string(.AppBackground.auraScheduleHint)) } }
        }
        .onAppear { paletteDark = dark }
        // 只在分钟变化时刷新选中态，避免让整个设置表单跟随每个动画帧重建。
        .onReceive(model.playback.$date.map { Int($0.timeIntervalSince1970 / 60) }.removeDuplicates()) {
            selectionDate = Date(timeIntervalSince1970: Double($0 * 60))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result { case .success(let url): model.importTheme(url); case .failure(let error): model.showImportError(error) }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            switch result { case .success(let url): model.extractPalette(url, paletteDark: paletteDark, appearanceDark: dark); case .failure(let error): model.showImportError(error) }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "ArcKit-Theme") {
            if case .failure(let error) = $0 { model.showImportError(error) }
        }
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string(.AppBackground.auraSave)).font(.headline)
                TextField(L10n.string(.AppBackground.auraName), text: $name)
                HStack {
                    Spacer()
                    Button(L10n.string(.Common.cancel)) { naming = false }.keyboardShortcut(.cancelAction)
                    Button(L10n.string(.Common.save)) { model.saveTheme(name: name, dark: dark); naming = false }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                }
            }.padding(24).frame(width: 360)
        }
        .confirmationDialog(L10n.string(.AppBackground.auraDeleteConfirm), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.string(.AppBackground.auraDelete), role: .destructive) { if let id = deleting { model.deleteTheme(id) }; deleting = nil }
        } message: { Text(L10n.string(.AppBackground.auraDeleteHint)) }
    }

    private func grid(_ themes: [AuraTheme]) -> some View {
        ViewThatFits(in: .horizontal) {
            themeGrid(themes, columns: 3).frame(minWidth: 440)
            themeGrid(themes, columns: 2)
        }
    }
    private func themeGrid(_ themes: [AuraTheme], columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
            ForEach(themes) { theme in
                AuraThemeCard(theme: theme, selected: theme.id == selected.id,
                              favorite: model.settings.aura.favorites.contains(theme.id)) { model.selectTheme(theme.id) }
                    .contextMenu {
                        Button(model.settings.aura.favorites.contains(theme.id) ? L10n.string(.AppBackground.auraUnfavorite) : L10n.string(.AppBackground.auraFavorite)) { model.toggleThemeFavorite(theme.id) }
                        Button(L10n.string(.AppBackground.auraDuplicate)) { var copy = theme; copy.name = theme.title; model.addTheme(copy) }
                        if !AuraTheme.builtinIDs.contains(theme.id) {
                            Button(L10n.string(.AppBackground.auraDelete), role: .destructive) { deleting = theme.id }
                        }
                    }
            }
        }.padding(.vertical, 4)
    }
    private var paletteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.string(.AppBackground.auraColors), selection: $paletteDark) {
                Text(L10n.string(.AppBackground.auraLight)).tag(false)
                Text(L10n.string(.AppBackground.auraDark)).tag(true)
            }.pickerStyle(.segmented)
            HStack(spacing: 12) {
                let colors = paletteDark ? selected.dark : selected.light
                ForEach(colors.indices, id: \.self) { index in
                    ColorPicker(L10n.string(.AppBackground.auraColor), selection: Binding(get: {
                        let current = paletteDark ? selected.dark : selected.light
                        return Color(auraRGB: current[min(index, current.count - 1)])
                    }, set: { color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        let value = UInt32((min(1, max(0, rgb.redComponent)) * 255).rounded()) << 16 | UInt32((min(1, max(0, rgb.greenComponent)) * 255).rounded()) << 8 | UInt32((min(1, max(0, rgb.blueComponent)) * 255).rounded())
                        model.editTheme(dark: dark) {
                            if paletteDark, index < $0.dark.count { $0.dark[index] = value }
                            else if !paletteDark, index < $0.light.count { $0.light[index] = value }
                        }
                    }), supportsOpacity: false).labelsHidden()
                }
                Spacer()
                Button { model.editTheme(dark: dark) { if paletteDark { $0.dark.append(0x65789A) } else { $0.light.append(0xC9AECF) } } } label: { ArcIcon(.plus, size: 13) }
                    .disabled(colors.count >= 5).help(L10n.string(.AppBackground.auraAddColor)).accessibilityLabel(L10n.string(.AppBackground.auraAddColor))
                Button { model.editTheme(dark: dark) { if paletteDark { $0.dark.removeLast() } else { $0.light.removeLast() } } } label: { ArcIcon(.trash2, size: 13) }
                    .disabled(colors.count <= 3).help(L10n.string(.AppBackground.auraRemoveColor)).accessibilityLabel(L10n.string(.AppBackground.auraRemoveColor))
            }
        }.padding(.vertical, 8)
    }
    private func binding<T>(_ path: WritableKeyPath<AppBackgroundSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }
    private func themeBinding<T>(_ path: WritableKeyPath<AuraTheme, T>) -> Binding<T> {
        Binding(get: { selected[keyPath: path] }, set: { value in model.editTheme(dark: dark) { $0[keyPath: path] = value } })
    }
    private func timeBinding(_ path: WritableKeyPath<AppBackgroundSettings, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = model.settings[keyPath: path]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.update { $0[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
        })
    }
    private func themePicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) { ForEach(allThemes) { Text($0.title).tag($0.id) } }
    }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(minWidth: 105, alignment: .leading)
            Slider(value: value, in: range) { Text(title) }.labelsHidden()
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
        }
    }
}

private struct AuraThemeCard: View {
    let theme: AuraTheme
    let selected: Bool
    let favorite: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appBackgroundReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.auraEnergySaving) private var energySaving
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.appBackgroundWindowVisible) private var visible
    var body: some View {
        let animates = (hovered || focused) && visible && activeState != .inactive && !reduceMotion && !appReduceMotion && !reduceTransparency && !energySaving
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animates)) { timeline in
                    AuraArtwork(theme: theme, time: animates ? timeline.date.timeIntervalSinceReferenceDate * 0.45 : 0, solid: reduceTransparency)
                }.frame(height: 76).overlay(alignment: .topTrailing) {
                    if selected { ArcIcon(.checkCircle, size: 16).foregroundStyle(.white).padding(5).background(.blue, in: Circle()).padding(8) }
                }
                HStack {
                    Text(theme.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    if favorite { ArcIcon(.sparkles, size: 12).foregroundStyle(.secondary) }
                }.padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.blue : .primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain).focused($focused).onHover { hovered = $0 }
            .accessibilityLabel(theme.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AuraExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(theme: AuraTheme) throws {
        _ = try theme.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(AuraThemeDocument(theme: theme))
    }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        _ = try AuraThemeDocument.decode(bytes); data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
