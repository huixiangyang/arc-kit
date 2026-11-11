import AppKit
import ArcKitPlatform

/// 菜单栏专用的小尺寸彩色绘制；保留品牌拱形与断开的右下角，不改应用内的大尺寸标志。
@MainActor
enum MenuBarIconArtwork {
    static let brand = render(size: NSSize(width: 18, height: 18)) { drawBrand() }
    private static let combinedSize = NSSize(width: 38, height: 18)
    static let combined = render(size: combinedSize) { drawCombined() }
    static let animationFrameCount = 40
    static let animationFrameInterval: TimeInterval = 0.05
    static let animationRestInterval: TimeInterval = 6
    private static let brandFrames = (0..<animationFrameCount).map { index in
        render(size: NSSize(width: 18, height: 18)) { drawBrand(phase: phase(for: index)) }
    }
    private static let combinedFrames = (0..<animationFrameCount).map { index in
        render(size: combinedSize) { drawCombined(phase: phase(for: index)) }
    }

    static func frame(_ index: Int, collectionVisible: Bool) -> NSImage {
        collectionVisible ? combinedFrames[index] : brandFrames[index]
    }

    private static func phase(for index: Int) -> Double { Double(index) / Double(animationFrameCount - 1) }

    #if DEBUG
    /// 放大图直接重绘相同轮廓，原尺寸预览仍使用正式位图，避免放大插值掩盖真实像素。
    static let detailPreview = render(size: NSSize(width: 114, height: 54)) {
        NSGraphicsContext.current!.cgContext.scaleBy(x: 3, y: 3)
        drawCombined()
    }

    static func animationDetailPreview(frame index: Int) -> NSImage {
        render(size: NSSize(width: 114, height: 54)) {
            NSGraphicsContext.current!.cgContext.scaleBy(x: 3, y: 3)
            drawCombined(phase: phase(for: index))
        }
    }
    #endif

    private static func drawCombined(phase: Double? = nil) {
        let context = NSGraphicsContext.current!.cgContext
        // 三点仍使用 Lucide ellipsis，只着色，不改变原来的形状或点击边界。
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        ArcIconImage.image(.ellipsis).draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
        NSColor(srgbRed: 0.90, green: 0.40, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 1, width: 16, height: 16).fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.saveGState()
        context.translateBy(x: 20, y: 0)
        drawBrand(phase: phase)
        context.restoreGState()
    }

    private static func drawBrand(phase: Double? = nil) {
        // 直接按 18pt 网格绘制，避免缩小大图时损失边缘和品牌右下角的断口。
        let arch = NSBezierPath()
        arch.move(to: NSPoint(x: 2, y: 2))
        arch.line(to: NSPoint(x: 2, y: 9))
        arch.curve(to: NSPoint(x: 9, y: 16), controlPoint1: NSPoint(x: 2, y: 12.866), controlPoint2: NSPoint(x: 5.134, y: 16))
        arch.curve(to: NSPoint(x: 16, y: 9), controlPoint1: NSPoint(x: 12.866, y: 16), controlPoint2: NSPoint(x: 16, y: 12.866))
        arch.line(to: NSPoint(x: 16, y: 6.2))
        arch.line(to: NSPoint(x: 12.5, y: 6.2))
        arch.line(to: NSPoint(x: 12.5, y: 9))
        arch.curve(to: NSPoint(x: 9, y: 12.5), controlPoint1: NSPoint(x: 12.5, y: 10.933), controlPoint2: NSPoint(x: 10.933, y: 12.5))
        arch.curve(to: NSPoint(x: 5.5, y: 9), controlPoint1: NSPoint(x: 7.067, y: 12.5), controlPoint2: NSPoint(x: 5.5, y: 10.933))
        arch.line(to: NSPoint(x: 5.5, y: 2))
        arch.close()
        let foot = NSBezierPath(roundedRect: NSRect(x: 12.5, y: 2, width: 3.5, height: 3.2), xRadius: 0.35, yRadius: 0.35)

        // 极细的深色轮廓在浅色菜单栏上保持边缘；不用外发光或底板挤占菜单栏空间。
        NSColor(srgbRed: 0.35, green: 0.10, blue: 0.27, alpha: 0.32).setStroke()
        for path in [arch, foot] { path.lineWidth = 0.5; path.stroke() }
        NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 1, green: 0.70, blue: 0.29, alpha: 1), 0),
            (NSColor(srgbRed: 1, green: 0.31, blue: 0.34, alpha: 1), 0.45),
            (NSColor(srgbRed: 0.72, green: 0.22, blue: 0.81, alpha: 1), 1))!
            .draw(in: arch, angle: -38)
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.81, blue: 0.39, alpha: 1),
            ending: NSColor(srgbRed: 1, green: 0.43, blue: 0.19, alpha: 1))!
            .draw(in: foot, angle: -65)

        // 一道短高光表现釉面厚度，保留纯净的内孔，不叠加小尺寸下会发糊的纹理。
        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: 2.6, y: 8.8))
        highlight.curve(to: NSPoint(x: 9, y: 15.4), controlPoint1: NSPoint(x: 2.6, y: 12.65), controlPoint2: NSPoint(x: 5.45, y: 15.4))
        highlight.curve(to: NSPoint(x: 13.3, y: 13.75), controlPoint1: NSPoint(x: 10.8, y: 15.4), controlPoint2: NSPoint(x: 12.3, y: 14.8))
        highlight.lineWidth = 0.5; highlight.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        highlight.stroke()

        if let phase {
            // 高光只在既有轮廓内移动；不缩放、不位移，三点与左右命中区始终固定。
            let eased = phase * phase * (3 - 2 * phase)
            let silhouette = arch.copy() as! NSBezierPath
            silhouette.append(foot)
            NSGraphicsContext.saveGraphicsState()
            silhouette.addClip()
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: -8 + 34 * eased, y: 9)
            context.rotate(by: -.pi / 8)
            NSGradient(colorsAndLocations:
                (NSColor.white.withAlphaComponent(0), 0),
                (NSColor.white.withAlphaComponent(0.12), 0.30),
                (NSColor.white.withAlphaComponent(0.65), 0.5),
                (NSColor.white.withAlphaComponent(0.12), 0.70),
                (NSColor.white.withAlphaComponent(0), 1))!
                .draw(in: NSRect(x: -3.5, y: -22, width: 7, height: 44), angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func render(size: NSSize, draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        // 预生成标准和 Retina 位图，不把主执行器绘制闭包交给系统后台渲染。
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = false
        return image
    }
}
