import ArcKitPlatform
import SwiftUI

struct WallpaperPlaybackView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        Form {
            WallpaperDisplaysSettings(model: model)
            Section(L10n.string(.WallpaperPlayback.playbackAutomaticRotation)) {
                Toggle(L10n.string(.WallpaperPlayback.playbackChangeWallpaperSchedule), isOn: preference(\.rotationEnabled))
                Picker(L10n.string(.WallpaperPlayback.playbackInterval), selection: preference(\.interval)) {
                    ForEach(WallpaperInterval.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L10n.string(.WallpaperPlayback.playbackShuffle), isOn: preference(\.shuffle))
                Toggle(L10n.string(.WallpaperPlayback.playbackFavorites), isOn: preference(\.favoritesOnly))
                displayPicker
                Picker(L10n.string(.WallpaperPlayback.playbackRotationScaling), selection: preference(\.scaling)) {
                    ForEach(WallpaperScaling.allCases) { Text($0.title).tag($0) }
                }
                Button(L10n.string(.WallpaperPlayback.playbackChangeNow), action: model.nextWallpaper).disabled(model.isPreview || model.catalog.items.isEmpty)
                Text(L10n.string(.WallpaperPlayback.playbackRotationAffectsSelectedScopeAll)).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.string(.WallpaperPlayback.playbackVideoPlaybackAllDisplays)) {
                HStack {
                    Text(model.hasDynamicWallpaper ? (model.videoPaused ? L10n.string(.Common.paused) : L10n.string(.WallpaperPlayback.playbackVideoWallpaperConfigured)) : L10n.string(.WallpaperPlayback.playbackLiveWallpaperSetMissing))
                    Spacer()
                    Button(model.videoPaused ? L10n.string(.WallpaperPlayback.playbackResume) : L10n.string(.WallpaperPlayback.playbackPause), action: model.toggleVideoPause).disabled(!model.hasDynamicWallpaper || model.isPreview)
                    Button(L10n.string(.Common.stop), action: model.stopDynamicWallpaper).disabled(!model.hasDynamicWallpaper)
                }
                Text(L10n.string(.WallpaperPlayback.playbackSupportsMp4MovM4VSilent)).font(.caption).foregroundStyle(.secondary)
            }
            if model.isPreview { Text(L10n.string(.WallpaperPlayback.playbackDebugScope)).font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).appBackgroundSurface().disabled(model.isBusy || !model.isLoaded)
    }

    private var displayPicker: some View {
        Picker(L10n.string(.WallpaperPlayback.playbackRotationDisplays), selection: preference(\.displayID)) {
            Text(L10n.string(.WallpaperPlayback.playbackAllDisplays)).tag("all")
            ForEach(model.displays) { Text(model.displayTitle($0)).tag($0.id) }
            if model.catalog.preferences.displayID != "all", !model.displays.contains(where: { $0.id == model.catalog.preferences.displayID }) {
                Text(L10n.string(.WallpaperPlayback.playbackDisconnectedDisplays)).tag(model.catalog.preferences.displayID)
            }
        }
    }

    private func preference<Value>(_ path: WritableKeyPath<WallpaperPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.catalog.preferences[keyPath: path] }, set: { value in
            var preferences = model.catalog.preferences; preferences[keyPath: path] = value
            model.updatePreferences(preferences)
        })
    }
}
