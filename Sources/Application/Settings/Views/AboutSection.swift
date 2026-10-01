import ArcKitPlatform
import SwiftUI

/// 关于信息作为偏好页的按需内容，不再重复罗列整套功能清单。
struct AboutSection: View {
    @ObservedObject var updateService: ArcKitUpdateService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ArcBrandMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Arc Kit")
                        .font(.system(size: 13))
                    Text(L10n.string(.About.aboutVersion(String(describing: versionText))))
                        .font(.subheadline)
                        .foregroundStyle(ArcPalette.secondaryText)
                }
                Spacer()
            }

            Divider().overlay(ArcPalette.divider)

            LabeledContent(L10n.string(.About.aboutWebsite)) {
                Link(ArcKitDistribution.websiteURL.host!, destination: ArcKitDistribution.websiteURL)
            }
            LabeledContent("GitHub") {
                Link("huixiangyang/arc-kit", destination: ArcKitDistribution.repositoryURL)
            }
            LabeledContent(L10n.string(.About.aboutRuntimeEnvironment), value: "macOS 13.0+ · \(architectureText)")
            LabeledContent(L10n.string(.About.aboutRuntimeComponents), value: "Finder Sync + LaunchAgent")

            Divider().overlay(ArcPalette.divider)

            updateContent

            Divider().overlay(ArcPalette.divider)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(.About.aboutPrivacy))
                    .font(.subheadline.weight(.medium))
                Text(L10n.string(.About.aboutPrivacyDetails))
                    .font(.caption)
                    .foregroundStyle(ArcPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
    }

    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(.About.aboutSoftwareUpdate))
                        .font(.subheadline.weight(.medium))
                    Text(L10n.string(updateService.isAvailable
                        ? .About.aboutSparkleUpdates
                        : .About.aboutUpdatesUnavailable))
                        .font(.caption)
                        .foregroundStyle(ArcPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L10n.string(.About.aboutCheckUpdates), action: updateService.checkForUpdates)
                    .disabled(!updateService.canCheckForUpdates)
            }
            Toggle(L10n.string(.About.aboutAutomaticUpdates), isOn: Binding(
                get: { updateService.automaticChecksEnabled },
                set: { updateService.setAutomaticChecksEnabled($0) }
            ))
            .disabled(!updateService.isAvailable)
            Toggle(L10n.string(.About.aboutAutomaticDownloads), isOn: Binding(
                get: { updateService.automaticDownloadsEnabled },
                set: { updateService.setAutomaticDownloadsEnabled($0) }
            ))
            .disabled(!updateService.isAvailable || !updateService.automaticChecksEnabled)
            if let lastCheck = updateService.lastUpdateCheckDate {
                LabeledContent(L10n.string(.About.aboutLastUpdateCheck)) {
                    Text(lastCheck, format: .dateTime.year().month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(ArcPalette.secondaryText)
            }
            Text(L10n.string(.About.aboutUnsignedDistribution))
                .font(.caption)
                .foregroundStyle(ArcPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Link(L10n.string(.About.aboutReleaseNotes), destination: ArcKitDistribution.releasesURL)
                .font(.caption)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version)（\(build)）"
    }

    private var architectureText: String {
        #if arch(arm64)
        "Apple Silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        L10n.string(.Common.unknown)
        #endif
    }
}
