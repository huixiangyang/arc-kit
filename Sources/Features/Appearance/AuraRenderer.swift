import AppKit
import SwiftUI

extension Color {
    init(auraRGB value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}

@MainActor
final class AuraPlaybackClock: ObservableObject {
    @Published private(set) var time = 0.0
    @Published private(set) var date = Date()
    @Published var pointer = CGPoint.zero
    private var phase = AuraPhase()

    func run(settings: AppBackgroundSettings, dark: Bool, visible: Bool, animates: Bool) async {
        var previous = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            date = Date()
            let theme = settings.aura.resolved(in: settings.themes, at: date, dark: dark)
            let rate = animates && settings.style == .aura ? theme.motion.rate : 0
            if rate > 0 {
                let now = ProcessInfo.processInfo.systemUptime
                phase.advance(seconds: now - previous, rate: rate)
                previous = now
                time = phase.time
            }
            let scheduled = visible && settings.style == .aura && settings.aura.automation == .schedule && !settings.aura.manualOverride
            if rate == 0 && !scheduled { return }
            let interval = rate > 0 ? 0.042 : max(0.1, 60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
        }
    }
}

/// 窗口只拥有一个时钟；所有背景切片消费相同相位，切换正文不会创建新的动画时间线。
struct AppBackgroundRuntime: ViewModifier {
    @ObservedObject var model: AppBackgroundModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appBackgroundReduceMotion) private var appReduceMotion
    @State private var energySaving = Self.energySaving

    private static var energySaving: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    }
    private var runs: Bool {
        model.isWindowVisible && activeState != .inactive && !reduceMotion && !appReduceMotion && !reduceTransparency && !energySaving
    }
    private struct PlaybackRequest: Equatable {
        let settings: AppBackgroundSettings
        let dark: Bool
        let visible: Bool
        let animates: Bool
    }
    private var request: PlaybackRequest {
        PlaybackRequest(settings: model.settings, dark: scheme == .dark, visible: model.isWindowVisible, animates: runs)
    }
    func body(content: Content) -> some View {
        content
            .environment(\.auraEnergySaving, energySaving)
            .task(id: request) {
                await model.playback.run(settings: request.settings, dark: request.dark, visible: request.visible, animates: request.animates)
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in energySaving = Self.energySaving }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in energySaving = Self.energySaving }
            .onContinuousHover { phase in
                guard runs, model.settings.style == .aura, model.settings.aura.parallax else { return }
                switch phase {
                case .active(let point):
                    // 由窗口尺寸归一化；只监听本窗口，不申请全局输入权限。
                    if let size = NSApp.keyWindow?.contentView?.bounds.size, size.width > 0, size.height > 0 {
                        model.playback.pointer = CGPoint(x: min(1, max(-1, point.x / size.width * 2 - 1)),
                                                         y: min(1, max(-1, point.y / size.height * 2 - 1)))
                    }
                case .ended: model.playback.pointer = .zero
                }
            }
            .onChange(of: runs) { if !$0 { model.playback.pointer = .zero } }
            .onChange(of: model.settings.aura.parallax) { if !$0 { model.playback.pointer = .zero } }
    }
}
private struct AuraEnergySavingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var auraEnergySaving: Bool {
        get { self[AuraEnergySavingKey.self] }
        set { self[AuraEnergySavingKey.self] = newValue }
    }
}

struct AuraWindowCanvas: View {
    let settings: AppBackgroundSettings
    @ObservedObject var clock: AuraPlaybackClock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appBackgroundReduceMotion) private var appReduceMotion
    @Environment(\.auraEnergySaving) private var energySaving
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.appBackgroundWindowVisible) private var visible
    var body: some View {
        let theme = settings.aura.resolved(in: settings.themes, at: clock.date, dark: scheme == .dark)
        AuraArtwork(theme: theme, time: clock.time, intensity: settings.opacity,
                    particles: theme.particles, grain: theme.grain,
                    pointer: settings.aura.parallax && !reduceMotion && !appReduceMotion && !energySaving ? clock.pointer : .zero,
                    solid: reduceTransparency)
            .id(theme.id)
            .transition(.opacity)
            .animation(reduceMotion || appReduceMotion || energySaving || !visible || activeState == .inactive ? nil : .easeInOut(duration: 0.45), value: theme.id)
    }
}

/// 渐变、雾层和光带共用归一化坐标，缩略图与完整窗口使用同一绘制器。
struct AuraArtwork: View {
    let theme: AuraTheme
    var time = 0.0
    var intensity = 0.75
    var particles = 0.0
    var grain = 0.0
    var pointer = CGPoint.zero
    var solid = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = scheme == .dark ? theme.dark : theme.light
        ZStack {
            Color(auraRGB: palette[0])
            if !solid {
                Canvas { context, size in
                    let colors = Array(palette.dropFirst()).map { Color(auraRGB: $0) }
                    let length = max(size.width, size.height)
                    let shift = Double(theme.seed % 101) / 101 * .pi * 2
                    for (index, color) in colors.enumerated() {
                        let n = Double(index)
                        let phase = time / (21 + n * 4) + shift + n * 2.1
                        let center = CGPoint(x: size.width * (0.5 + cos(phase) * 0.34 + theme.x + pointer.x * 0.025),
                                             y: size.height * (0.5 + sin(phase * 0.8 + n) * 0.37 + theme.y + pointer.y * 0.025))
                        var layer = context
                        switch theme.form {
                        case .glow, .mist:
                            let radius = length * (theme.form == .mist ? 0.73 : 0.62) * theme.spread
                            layer.opacity = theme.form == .mist ? 0.67 : 0.8
                            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                                Gradient(colors: [color, color.opacity(0.45), color.opacity(0)]), center: center,
                                startRadius: 0, endRadius: radius))
                            if theme.form == .mist {
                                let fog = CGRect(x: -size.width * 0.2, y: center.y - size.height * 0.24,
                                                 width: size.width * 1.4, height: size.height * 0.58)
                                layer.addFilter(.blur(radius: min(size.width, size.height) * 0.08))
                                layer.fill(Path(ellipseIn: fog), with: .color(color.opacity(0.28)))
                            }
                        case .ribbon:
                            var path = Path()
                            let y = size.height * (0.22 + n * 0.22 + theme.y)
                            path.move(to: CGPoint(x: -size.width * 0.2, y: y))
                            path.addCurve(to: CGPoint(x: size.width * 1.2, y: y + sin(phase) * size.height * 0.25),
                                control1: CGPoint(x: size.width * (0.15 + theme.x), y: y + cos(phase) * size.height * 0.7),
                                control2: CGPoint(x: size.width * (0.78 + theme.x), y: y - sin(phase + 1) * size.height * 0.62))
                            layer.translateBy(x: pointer.x * size.width * 0.025, y: pointer.y * size.height * 0.025)
                            layer.addFilter(.blur(radius: max(8, size.height * 0.045)))
                            layer.stroke(path, with: .linearGradient(Gradient(colors: [color.opacity(0), color, color.opacity(0.12)]),
                                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)),
                                style: StrokeStyle(lineWidth: size.height * 0.26 * theme.spread, lineCap: .round))
                        }
                    }
                    if particles > 0 {
                        for index in 0..<Int(48 * particles) {
                            let seed = Double((index * 37 + theme.seed) % 101) / 101
                            let x = (seed + sin(time / 30 + Double(index)) * 0.02) * size.width
                            let y = (Double(index * 61 % 97) / 97 - time / (100 + Double(index))).truncatingRemainder(dividingBy: 1)
                            let radius = max(0.7, min(size.width, size.height) / 600) * (1 + Double(index % 3) * 0.3)
                            context.fill(Path(ellipseIn: CGRect(x: x, y: (y < 0 ? y + 1 : y) * size.height, width: radius * 2, height: radius * 2)),
                                         with: .color((scheme == .dark ? Color.white : Color(auraRGB: palette[1])).opacity(0.16 + seed * 0.16)))
                        }
                    }
                }.opacity(intensity)
                if grain > 0 {
                    Image(decorative: AuraGrain.image, scale: 1).resizable(resizingMode: .tile)
                        .opacity(grain * 0.12).blendMode(.softLight)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private enum AuraGrain {
    /// 单次生成的确定性纹理，动画帧只重复采样，不重新分配噪声位图。
    static let image: CGImage = {
        var bytes = [UInt8](repeating: 0, count: 64 * 64)
        var state: UInt32 = 0xA7C137
        for index in bytes.indices { state = state &* 1_664_525 &+ 1_013_904_223; bytes[index] = UInt8(state >> 24) }
        return CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
}
