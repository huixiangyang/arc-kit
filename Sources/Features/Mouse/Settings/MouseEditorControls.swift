import ArcKitPlatform
import ArcKitMouse
import SwiftUI

struct MouseSliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Self.formatted(value.wrappedValue)) \(suffix)")
                Text("\(Self.formatted(value.wrappedValue))\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
            }
            .frame(width: 240)
        }
    }

    static func formatted(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }
}

struct MouseModifierPicker: View {
    let title: String
    let selection: Binding<MouseModifierGesture>

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(MouseModifierGesture.allCases, id: \.self) { gesture in
                Text(gesture.displayName).tag(gesture)
            }
        }
    }
}

struct MouseEditorFeedback: View {
    let text: String
    var verticalPadding: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ArcIcon(.circleInfo, size: 16)
                .foregroundStyle(ArcPalette.accent)
            Text(text)
                .font(.caption)
                .foregroundStyle(ArcPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, verticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    static func modifierReassignmentNotice(
        modifier: MouseModifierGesture,
        role: MouseScrollModifierRole,
        clearedRoles: [MouseScrollModifierRole]
    ) -> String? {
        guard modifier != .none, !clearedRoles.isEmpty else { return nil }
        let clearedNames = clearedRoles.map { "“\($0.displayName)”" }.joined(separator: "、")
        return L10n.string(.MouseSettings.modifierNowControlsPreviousSet(String(describing: modifier.displayName), String(describing: role.displayName), String(describing: clearedNames)))
    }
}
