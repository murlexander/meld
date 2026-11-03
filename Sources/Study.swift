import CoreImage
import AppKit

/// View-only studies for painters. They change the displayed preview, never the artwork or exports.
enum Study: String, CaseIterable, Identifiable {
    case colour = "Colour", values = "Values", notan = "Notan"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .colour: return "paintpalette"; case .values: return "circle.lefthalf.filled"; case .notan: return "circle.grid.2x1.left.filled" }
    }
    var help: String {
        switch self {
        case .colour: return "Show the preview in colour"
        case .values: return "Show light and dark values in greyscale"
        case .notan: return "Simplify into three values: dark, middle and light"
        }
    }

    func apply(_ image: CGImage, context: CIContext) -> CGImage? {
        guard self != .colour else { return image }
        var result = CIImage(cgImage: image).applyingFilter("CIPhotoEffectMono")
        if self == .notan {
            // Three luminance bands from the mono image; thresholds sit at thirds.
            result = result.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 3])
        }
        return context.createCGImage(result, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
    }
}

extension Ink {
    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
