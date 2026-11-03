import AppKit
import CoreImage
import ImageIO

/// One immutable, independent working copy shared by recipes, edits and undo.
/// Keeping decoded pixels avoids compressing to PNG and reopening it per render.
/// Its lifetime follows the artwork; there is no process-wide image cache.
final class SourceImage: Equatable {
    let pixels: CGImage
    let previewPixels: CGImage
    let thumbnail: CGImage
    let fullImage: CIImage
    let previewImage: CIImage
    /// Perceptual luminance on a coarse grid, rows from the top, for choosing crops cheaply.
    let values: [Double]
    static let valueGrid = 24

    static func == (lhs: SourceImage, rhs: SourceImage) -> Bool { lhs === rhs }

    init(_ pixels: CGImage) {
        self.pixels = pixels
        previewPixels = Self.resized(pixels, maximum: 1000) ?? pixels
        thumbnail = Self.resized(previewPixels, maximum: 96) ?? previewPixels
        fullImage = CIImage(cgImage: pixels)
        // Express both representations in the same coordinates, even when rounding
        // the thumbnail's dimensions would slightly change a non-square aspect.
        previewImage = CIImage(cgImage: previewPixels).transformed(by: CGAffineTransform(
            scaleX: CGFloat(pixels.width) / CGFloat(previewPixels.width),
            y: CGFloat(pixels.height) / CGFloat(previewPixels.height)))
        let n = Self.valueGrid
        var grid = [Double](repeating: 0.5, count: n * n)
        if let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = context.data?.assumingMemoryBound(to: UInt8.self) {
            context.interpolationQuality = .medium
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: n, height: n))
            for i in 0..<(n * n) { grid[i] = Double(data[i]) / 255 }
        }
        values = grid
    }
    /// Spread of values (with a little credit for light) in a window centred at `(x, y)`
    /// (fractions from the left and top) with half-size `half`: higher reads as clearer shapes.
    func valueStructure(x: Double, y: Double, half: Double) -> Double {
        let n = Self.valueGrid
        var samples: [Double] = []
        for row in 0..<n { for column in 0..<n {
            let u = (Double(column) + 0.5) / Double(n), v = (Double(row) + 0.5) / Double(n)
            if abs(u - x) <= half && abs(v - y) <= half { samples.append(values[row * n + column]) }
        }}
        if samples.isEmpty { samples = [values[min(n - 1, max(0, Int(y * Double(n)))) * n + min(n - 1, max(0, Int(x * Double(n))))]] }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let spread = (samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)).squareRoot()
        return spread + 0.2 * min(mean, 0.45)
    }

    convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200] as CFDictionary) else { return nil }
        self.init(image)
    }

    static func resized(_ image: CGImage, maximum: Int) -> CGImage? {
        let edge = max(image.width, image.height)
        guard edge > maximum else { return image }
        let factor = Double(maximum) / Double(edge)
        // Keep the source's colour space and alpha instead of flattening through sRGB.
        guard let context = CGContext(data: nil,
            width: max(1, Int(Double(image.width) * factor)), height: max(1, Int(Double(image.height) * factor)),
            bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage()
    }
}
