import AppKit
import CoreImage

final class Renderer {
    let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ art: Artwork, longEdge: Int, bypass: Bool = false) -> CGImage? {
        let ratio = art.ratio
        let w = ratio >= 1 ? longEdge : Int(Double(longEdge) * ratio)
        let h = ratio >= 1 ? Int(Double(longEdge) / ratio) : longEdge
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var composite = CIImage(color: CIColor(cgColor: art.background.cg)).cropped(to: rect)
        for layer in art.layers where layer.visible {
            var source: CIImage?
            if layer.material == .image, let data = layer.image { source = CIImage(data: data, options: [.applyOrientationProperty: true]) }
            else if let cg = Self.pattern(layer, w: w, h: h) { source = CIImage(cgImage: cg) }
            guard var source else { continue }
            let extent = source.extent
            let fit = max(CGFloat(w) / extent.width, CGFloat(h) / extent.height) * layer.scale
            let t = CGAffineTransform(translationX: CGFloat(w) * (0.5 + layer.x), y: CGFloat(h) * (0.5 - layer.y))
                .rotated(by: layer.rotation * .pi / 180).scaledBy(x: fit, y: fit)
                .translatedBy(x: -extent.midX, y: -extent.midY)
            source = source.transformed(by: t).cropped(to: rect)
            source = source.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
            composite = source.applyingFilter(layer.blend.filter, parameters: [kCIInputBackgroundImageKey: composite]).cropped(to: rect)
        }
        if !bypass {
            let warp = art.warp
            if warp.wave > 0.001, let map = Self.waveMap(w: w, h: h, frequency: warp.wavelength) {
                composite = composite.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": CIImage(cgImage: map), kCIInputScaleKey: warp.wave * Double(longEdge) * 0.35]).cropped(to: rect)
            }
            let center = CIVector(x: Double(w) * warp.centerX, y: Double(h) * (1 - warp.centerY))
            if abs(warp.twist) > 0.001 {
                composite = composite.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: Double(longEdge) * 0.7, kCIInputAngleKey: warp.twist]).cropped(to: rect)
            }
            if abs(warp.bulge) > 0.001 {
                composite = composite.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: Double(longEdge) * 0.55, kCIInputScaleKey: warp.bulge]).cropped(to: rect)
            }
            if warp.pixel > 0.002 {
                composite = composite.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, warp.pixel * Double(longEdge) * 0.12), kCIInputCenterKey: center]).cropped(to: rect)
            }
            composite = composite.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: warp.saturation, kCIInputContrastKey: warp.contrast]).cropped(to: rect)
        }
        return context.createCGImage(composite, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    static func canvas(w: Int, h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func normalizedPNG(_ cg: CGImage, maximum: Int) -> Data? {
        let f = min(1, Double(maximum) / Double(max(cg.width, cg.height)))
        guard let ctx = canvas(w: max(1, Int(Double(cg.width) * f)), h: max(1, Int(Double(cg.height) * f))) else { return nil }
        ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        guard let result = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
    static func pattern(_ l: Layer, w: Int, h: Int) -> CGImage? {
        guard let ctx = canvas(w: w, h: h) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(l.paper.cg); ctx.fill(r); ctx.setFillColor(l.ink.cg); ctx.setStrokeColor(l.ink.cg)
        let step = Double(max(w, h)) / l.frequency
        switch l.material {
        case .stripes:
            for i in 0...Int(ceil(Double(w) / step)) { ctx.fill(CGRect(x: Double(i) * step, y: 0, width: step * 0.48, height: Double(h))) }
        case .dots:
            for x in 0...Int(ceil(Double(w) / step)) { for y in 0...Int(ceil(Double(h) / step)) {
                ctx.fillEllipse(in: CGRect(x: Double(x) * step, y: Double(y) * step, width: step * 0.5, height: step * 0.5))
            }}
        case .checker:
            for x in 0...Int(ceil(Double(w) / step)) { for y in 0...Int(ceil(Double(h) / step)) where (x + y) % 2 == 0 {
                ctx.fill(CGRect(x: Double(x) * step, y: Double(y) * step, width: step, height: step))
            }}
        case .rings:
            ctx.setLineWidth(step * 0.35)
            for i in 1...Int(l.frequency * 1.5) {
                let diameter = Double(i) * step * 2
                ctx.strokeEllipse(in: CGRect(x: Double(w) / 2 - diameter / 2, y: Double(h) / 2 - diameter / 2, width: diameter, height: diameter))
            }
        case .noise:
            var seed: UInt64 = 812367
            let cell = max(1, Int(step / 8))
            for y in stride(from: 0, to: h, by: cell) { for x in stride(from: 0, to: w, by: cell) {
                seed = seed &* 6364136223846793005 &+ 1
                let v = Double((seed >> 33) % 1000) / 999
                ctx.setFillColor(CGColor(red: l.paper.r * (1-v) + l.ink.r*v, green: l.paper.g*(1-v)+l.ink.g*v, blue: l.paper.b*(1-v)+l.ink.b*v, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }}
        case .image: break
        }
        return ctx.makeImage()
    }
    static func waveMap(w: Int, h: Int, frequency: Double) -> CGImage? {
        // A small displacement map scales smoothly at preview and export sizes.
        let mw = 256, mh = max(1, Int(256 * Double(h) / Double(w)))
        guard let ctx = canvas(w: mw, h: mh), let buffer = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<mh { for x in 0..<mw {
            let u = Double(x) / Double(mw), v = Double(y) / Double(mh)
            let i = y * ctx.bytesPerRow + x * 4
            buffer[i] = UInt8((0.5 + 0.48 * sin(v * frequency * .pi * 2 + u * 2)) * 255)
            buffer[i+1] = UInt8((0.5 + 0.48 * cos(u * frequency * .pi * 2 + v * 3)) * 255)
            buffer[i+2] = 128; buffer[i+3] = 255
        }}
        return ctx.makeImage().flatMap { small in
            guard let full = canvas(w: w, h: h) else { return nil }
            full.interpolationQuality = .high; full.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h)); return full.makeImage()
        }
    }
    static func starterPNG() -> Data? {
        guard let c = canvas(w: 1200, h: 1200) else { return nil }
        c.setFillColor(Ink(0.94, 0.72, 0.38).cg); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
        let colours = [Ink(0.07,0.17,0.36), Ink(0.28,0.44,0.65), Ink(0.86,0.29,0.26), Ink(0.93,0.85,0.68), Ink(0.08,0.3,0.31)]
        c.setFillColor(colours[0].cg)
        c.move(to: CGPoint(x: 0, y: 180)); c.addCurve(to: CGPoint(x: 1200, y: 740), control1: CGPoint(x: 650, y: -240), control2: CGPoint(x: 300, y: 1150)); c.addLine(to: CGPoint(x: 1200, y: 1200)); c.addLine(to: CGPoint(x: 0, y: 1200)); c.closePath(); c.fillPath()
        c.setFillColor(colours[1].cg); c.fillEllipse(in: CGRect(x: 130, y: 240, width: 570, height: 830))
        c.setFillColor(colours[2].cg); c.fillEllipse(in: CGRect(x: 590, y: 520, width: 500, height: 500))
        c.setFillColor(colours[3].cg); c.fillEllipse(in: CGRect(x: 300, y: 600, width: 330, height: 330))
        c.setFillColor(colours[4].cg)
        c.move(to: CGPoint(x: 0,y: 0)); c.addLine(to: CGPoint(x: 1200,y: 0)); c.addLine(to: CGPoint(x: 1200,y: 310)); c.addCurve(to: CGPoint(x: 0,y: 130),control1: CGPoint(x: 750,y: 620),control2: CGPoint(x: 280,y: -100)); c.closePath(); c.fillPath()
        c.setStrokeColor(Ink(0.97,0.86,0.59).cg); c.setLineWidth(9)
        for i in 0..<6 { c.move(to: CGPoint(x: 80 + i*24, y: 710)); c.addCurve(to: CGPoint(x: 700 + i*24,y: 1050),control1: CGPoint(x: 400 + i*24,y: 650),control2: CGPoint(x: 400 + i*24,y: 1100)); c.strokePath() }
        guard let cg = c.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
