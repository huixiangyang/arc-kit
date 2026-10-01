import ArcKitPlatform
import SwiftUI

/// 用完整窗口的层次预览背景，文字与表单表面同时参与可读性检查。
struct AppBackgroundPreview: View {
    @ObservedObject var model: AppBackgroundModel
    @Environment(\.colorScheme) private var scheme
    @State private var previewDark: Bool?
    private var effectiveScheme: ColorScheme { previewDark.map { $0 ? .dark : .light } ?? scheme }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                AppBackgroundCanvas(settings: model.settings, image: model.image, clock: model.playback)
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { _ in Circle().fill(.primary.opacity(0.2)).frame(width: 6, height: 6) }
                        Spacer()
                        Text("Arc Kit").font(.system(size: 10, weight: .medium))
                        Spacer()
                        ArcIcon(.search, size: 10)
                    }.padding(12).background(.primary.opacity(0.025))
                    Divider()
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label { Text(L10n.string(.Common.settings)).font(.system(size: 10)) } icon: { ArcIcon(.settings, size: 12) }
                            Label { Text(L10n.string(.AppBackground.backgroundAppBackground)).font(.system(size: 10)) } icon: { ArcIcon(.image, size: 12) }
                                .padding(6).background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                            Spacer(minLength: 0)
                        }.padding(12).frame(width: 136, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.settings.style == .aura ? L10n.string(.AppBackground.auraThemes) : L10n.string(.AppBackground.backgroundAppBackground)).font(.system(size: 12, weight: .semibold))
                            VStack(spacing: 0) {
                                sampleRow(L10n.string(.AppBackground.auraIntensity), icon: .sun)
                                Divider()
                                sampleRow(L10n.string(.AppBackground.auraMotion), icon: .sparkles)
                            }.background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                            Text(L10n.string(.AppBackground.auraStatus)).font(.system(size: 9)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 196)
            .environment(\.colorScheme, effectiveScheme)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
            .accessibilityElement(children: .ignore).accessibilityLabel(L10n.string(.AppBackground.backgroundAppBackgroundPreview))
            if model.settings.style == .aura {
                HStack {
                    Text(L10n.string(.AppBackground.auraPreview)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker(L10n.string(.AppBackground.auraPreview), selection: Binding(get: { effectiveScheme == .dark }, set: { previewDark = $0 })) {
                        Text(L10n.string(.AppBackground.auraLight)).tag(false)
                        Text(L10n.string(.AppBackground.auraDark)).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
            }
        }
    }
    private func sampleRow(_ title: String, icon: ArcIconName) -> some View {
        HStack {
            ArcIcon(icon, size: 11).foregroundStyle(.secondary)
            Text(title).font(.system(size: 10)).lineLimit(1)
            Spacer()
            Capsule().fill(.primary.opacity(0.15)).frame(width: 36, height: 4)
        }.padding(9)
    }
}
