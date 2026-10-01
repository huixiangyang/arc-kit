import ArcKitPlatform
import AppKit
import UniformTypeIdentifiers
import SwiftUI

extension NSImage {
    var centerPixelColor: NSColor? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    }

    /// 转为 SwiftUI Image。
    var swiftUIImage: Image {
        Image(nsImage: self)
    }
}

extension NSColor {
    func hexString(includeHash: Bool) -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return includeHash ? "#000000" : "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        let v = String(format: "%02X%02X%02X", r, g, b)
        return includeHash ? "#\(v)" : v
    }
}

/// 使用系统 UTType 获取真实的文件类型图标。
struct FileTypeIconView: View {
    let ext: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let utType = UTType(filenameExtension: ext) {
               let icon = NSWorkspace.shared.icon(for: utType)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ArcIcon(.file, size: size * 0.8)
                    .foregroundStyle(ArcPalette.mutedText)
            }
        }
        .frame(width: size, height: size)
    }
}
