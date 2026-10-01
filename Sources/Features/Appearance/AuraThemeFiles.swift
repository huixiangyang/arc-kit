import ArcKitPlatform
import Foundation
import ImageIO
import CoreGraphics

/// 导入只读取用户选择的本地文件；取色完成后不保留原图引用。
enum AuraThemeFiles {
    static func readTheme(_ url: URL) throws -> AuraTheme {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try AuraThemeDocument.decode(ArcKitBoundedFileReader.read(from: url, maximumBytes: 65_536))
    }
    static func palette(_ url: URL, dark: Bool) throws -> [UInt32] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard url.isFileURL, info.isRegularFile == true, let bytes = info.fileSize, (1...104_857_600).contains(bytes),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { throw AppBackgroundError.message(L10n.string(.AppBackground.auraImageInvalid)) }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                                          bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered else { throw AppBackgroundError.message(L10n.string(.AppBackground.auraImageInvalid)) }
        var histogram: [UInt32: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let color = UInt32(pixels[i] & 0xF0) << 16 | UInt32(pixels[i + 1] & 0xF0) << 8 | UInt32(pixels[i + 2] & 0xF0)
            histogram[color, default: 0] += 1
        }
        var colors: [UInt32] = []
        for (candidate, _) in histogram.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            if colors.allSatisfy({ distance($0, candidate) > 2_000 }) { colors.append(candidate) }
            if colors.count == 3 { break }
        }
        guard let primary = colors.first else { throw AppBackgroundError.message(L10n.string(.AppBackground.auraImageInvalid)) }
        while colors.count < 3 { colors.append(mix(primary, with: dark ? 0xA0C0D0 : 0xE8D5C0, amount: Double(colors.count) * 0.22)) }
        let base = mix(primary, with: dark ? 0x151A22 : 0xF6F5F1, amount: 0.92)
        return [base] + colors.map { mix($0, with: dark ? 0x101820 : 0xFFFFFF, amount: dark ? 0.12 : 0.25) }
    }
    private static func distance(_ a: UInt32, _ b: UInt32) -> Double {
        var total = 0.0
        for shift in [16, 8, 0] {
            let first = Double((a >> shift) & 255)
            let second = Double((b >> shift) & 255)
            total += (first - second) * (first - second)
        }
        return total
    }
    private static func mix(_ a: UInt32, with b: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let first = Double((a >> shift) & 255), second = Double((b >> shift) & 255)
            return result | UInt32((first * (1 - amount) + second * amount).rounded()) << shift
        }
    }
}
