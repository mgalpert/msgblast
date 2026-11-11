import CoreGraphics

/// How light a transparent mark is, so it can get a faint backing where it would vanish:
/// a dark mark on a dark background, or a white mark on a light one.
public enum ArtworkTone {
    /// Average luminance (0 black … 1 white) of the image's opaque pixels, from a small
    /// downsample. Nil when nothing is opaque.
    public static func luminance(of image: CGImage, side: Int = 32) -> Double? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0, count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3])
            guard alpha >= 128 else { continue }
            // Premultiplied: divide the alpha back out.
            let r = Double(pixels[index]) / alpha, g = Double(pixels[index + 1]) / alpha, b = Double(pixels[index + 2]) / alpha
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            count += 1
        }
        return count == 0 ? nil : min(1, total / Double(count))
    }

    /// Below this a mark is too dark for a dark background.
    public static let darkMark = 0.35
    /// Above this a mark is too light for a light background.
    public static let lightMark = 0.8

    /// Whether a transparent mark of this luminance needs a backing in the current appearance.
    public static func needsBacking(luminance: Double?, darkBackground: Bool) -> Bool {
        guard let luminance else { return false }
        return darkBackground ? luminance < darkMark : luminance > lightMark
    }
}
