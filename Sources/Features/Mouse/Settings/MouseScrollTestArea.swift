import ArcKitPlatform
import ArcKitMouse
import AppKit
import SwiftUI

/// 只观察本视图真实收到的 NSEvent，不向系统合成输入，也不把后台 post 计数当作接收成功。
struct MouseScrollTestArea: View {
    @State private var received = 0
    @State private var enhanced = 0
    @State private var moved = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(.MouseSettings.testScrollTestArea)).font(.subheadline.weight(.medium))
            Text(L10n.string(.MouseSettings.testScrollOverScaleCompareReceived))
                .font(.caption).foregroundStyle(.secondary)
            ScrollConsumer { isEnhanced, distance in
                received += 1
                if isEnhanced { enhanced += 1 }
                moved += distance
            }
            .frame(height: 140)
            Text(L10n.string(.MouseSettings.testFrameStatistics(Int(received), Int(enhanced), Double(moved))))
                .font(.caption).monospacedDigit()
        }
    }

    private struct ScrollConsumer: NSViewRepresentable {
        var received: (Bool, Double) -> Void

        func makeNSView(context: Context) -> ConsumerScrollView {
            let view = ConsumerScrollView()
            view.hasVerticalScroller = false
            view.borderType = .bezelBorder
            view.documentView = Ruler(frame: NSRect(x: 0, y: 0, width: 600, height: 2400))
            view.contentView.scroll(to: NSPoint(x: 0, y: 1000))
            view.didReceive = received
            return view
        }

        func updateNSView(_ nsView: ConsumerScrollView, context: Context) { nsView.didReceive = received }
    }

    private final class ConsumerScrollView: NSScrollView {
        var didReceive: ((Bool, Double) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let before = contentView.bounds.origin.y
            super.scrollWheel(with: event)
            let enhanced = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == MouseScrollEventOrigin.syntheticMarker
            didReceive?(enhanced, Double(contentView.bounds.origin.y - before))
        }
    }

    private final class Ruler: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
            let line = NSBezierPath()
            for y in stride(from: 0, through: 2400, by: 40) where dirtyRect.intersects(NSRect(x: 0, y: y, width: 600, height: 40)) {
                line.move(to: NSPoint(x: 64, y: y))
                line.line(to: NSPoint(x: bounds.width, y: CGFloat(y)))
                ("\(y)" as NSString).draw(at: NSPoint(x: 12, y: y + 4), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            }
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
    }
}
