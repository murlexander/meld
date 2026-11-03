import AppKit
import CoreImage

final class Renderer {
    /// Renders finished in this process, so test waits can tell slow progress from a hang.
    private static let finishedLock = NSLock()
    private static var finishedCount = 0
    static var finished: Int { finishedLock.lock(); defer { finishedLock.unlock() }; return finishedCount }
    // Bound render-task memory as well as disabling cached intermediate buffers.
    let context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: 128])
    func render(_ art: Artwork, longEdge: Int, bypass: Bool = false) -> CGImage? {
        let ratio = art.ratio
        let w = ratio >= 1 ? longEdge : Int(Double(longEdge) * ratio)
        let h = ratio >= 1 ? Int(Double(longEdge) / ratio) : longEdge
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var composite = CIImage(color: CIColor(cgColor: art.background.cg)).cropped(to: rect)
        for layer in art.layers where layer.visible && layer.opacity > 0 {
            var source: CIImage?
            if layer.material == .image, let image = layer.image {
                source = longEdge <= 640 ? image.previewImage : image.fullImage
            }
            else if let cg = Self.pattern(layer, w: w, h: h) { source = CIImage(cgImage: cg) }
            guard var source else { continue }
            let extent = source.extent
            let repeats = layer.material == .image ? max(1, layer.tiles) : 1
            let fit = max(CGFloat(w) / extent.width, CGFloat(h) / extent.height) * layer.scale / CGFloat(repeats)
            // One-axis stretch about the layer centre, in canvas axes (matching `Coverage`).
            let along = layer.stretchAngle * .pi / 180
            let place = CGAffineTransform(translationX: CGFloat(w) * (0.5 + layer.x), y: CGFloat(h) * (0.5 - layer.y))
                .rotated(by: along).scaledBy(x: max(0.01, layer.stretch), y: 1).rotated(by: -along)
            var t = place.rotated(by: layer.rotation * .pi / 180).scaledBy(x: fit, y: fit)
                .translatedBy(x: -extent.midX, y: -extent.midY)
            if repeats > 1 {
                // Tiling reads its whole cell. Shrink the cell to its on-canvas pixel size
                // first; tiling at source resolution held hundreds of MB per render.
                let uw = max(1, min(extent.width, (extent.width * fit).rounded()))
                let uh = max(1, min(extent.height, (extent.height * fit).rounded()))
                let sx = uw / extent.width, sy = uh / extent.height
                let unit = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)))
                // Reflect adjacent cells across every edge. Sampling the edge-clamped cell keeps
                // borders opaque; cropping a mirrored cell for CIAffineTile left faint
                // background-coloured seams wherever the tiles were rotated.
                let unitExtent = CGRect(x: 0, y: 0, width: uw, height: uh)
                // Resampling can leave the cell's outermost pixels partly transparent; clamp
                // from one pixel inside so every repeat stays opaque, even at thumbnail sizes.
                let edgeSafe = uw > 4 && uh > 4 ? unit.cropped(to: unitExtent.insetBy(dx: 1, dy: 1)).clampedToExtent() : unit.clampedToExtent()
                if let tiled = Self.mirrorTile.apply(extent: .infinite, roiCallback: { _, _ in unitExtent.insetBy(dx: -2, dy: -2) },
                                                     image: edgeSafe, arguments: [CIVector(x: uw, y: uh)]) { source = tiled }
                // Same placement as before, expressed in the shrunken cell's coordinates.
                t = place.rotated(by: layer.rotation * .pi / 180).scaledBy(x: fit / sx, y: fit / sy)
                    .translatedBy(x: -extent.midX * sx, y: -extent.midY * sy)
            }
            source = source.transformed(by: t).cropped(to: rect)
            source = source.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity)])
            let blended = source.applyingFilter(layer.blend.filter, parameters: [kCIInputBackgroundImageKey: composite]).cropped(to: rect)
            if layer.mask != .none, let masked = Self.mask(layer, over: blended, below: composite, w: w, h: h) { composite = masked }
            else { composite = blended }
        }
        if !bypass {
            let warp = art.warp
            if warp.wave > 0.001, let map = Self.waveMap(w: w, h: h, frequency: warp.wavelength) {
                composite = composite.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": map, kCIInputScaleKey: warp.wave * Double(longEdge) * 0.35]).cropped(to: rect)
            }
            let center = CIVector(x: Double(w) * warp.centerX, y: Double(h) * (1 - warp.centerY))
            if abs(warp.twist) > 0.001 {
                composite = composite.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: Double(longEdge) * 0.7, kCIInputAngleKey: warp.twist]).cropped(to: rect)
            }
            if abs(warp.bulge) > 0.001 {
                composite = composite.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: Double(longEdge) * 0.55, kCIInputScaleKey: warp.bulge]).cropped(to: rect)
            }
            if warp.pixel > 0.002 {
                composite = composite.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, warp.pixel * Double(longEdge) * 0.12), kCIInputCenterKey: center]).cropped(to: rect)
            }
            composite = Self.effects(art.effects, on: composite, rect: rect, focus: center)
            composite = composite.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: warp.saturation, kCIInputContrastKey: warp.contrast]).cropped(to: rect)
            if art.effects.grain > 0.001 { composite = Self.grain(art.effects, over: composite, rect: rect) }
        }
        let image = context.createCGImage(composite, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
        Self.finishedLock.lock(); Self.finishedCount += 1; Self.finishedLock.unlock()
        return image
    }
    /// Mixes a blended layer into the composite below through a soft mask: the luminance of
    /// the layers below (bright or dark), or a linear or radial fade across the canvas.
    private static let maskKernel = CIColorKernel(source: """
        kernel vec4 meldMask(__sample top, __sample bottom, vec4 p, vec4 q) {
            float t;
            if (p.x < 1.5) {
                float l = pow(max(dot(bottom.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0), 0.4545);
                t = l;
            } else if (p.x < 2.5) {
                t = dot(destCoord() - q.xy, q.zw);
            } else {
                t = length(destCoord() - q.xy) * q.z;
            }
            float m = smoothstep(p.y, p.z, t);
            if (p.w > 0.5) { m = 1.0 - m; }
            return mix(bottom, top, m);
        }
        """)!
    static func mask(_ layer: Layer, over top: CIImage, below bottom: CIImage, w: Int, h: Int) -> CIImage? {
        let soft = max(0.01, layer.maskSoftness), pos = layer.maskPosition
        let mode: Double, invert: Double, q: CIVector
        switch layer.mask {
        case .none: return top
        case .bright, .dark:
            mode = 1; invert = layer.mask == .dark ? 1 : 0; q = CIVector(x: 0, y: 0, z: 0, w: 0)
        case .linear:
            // Distance along the fade direction in canvas heights; y runs upwards in Core Image.
            let a = layer.maskAngle * .pi / 180
            mode = 2; invert = 0
            q = CIVector(x: Double(w) / 2, y: Double(h) / 2, z: cos(a) / Double(h), w: sin(a) / Double(h))
        case .radial:
            mode = 3; invert = 1
            q = CIVector(x: Double(w) * layer.maskX, y: Double(h) * (1 - layer.maskY), z: 1 / Double(max(w, h)), w: 0)
        }
        let p = CIVector(x: mode, y: pos - soft, z: pos + soft, w: invert)
        return maskKernel.apply(extent: top.extent.intersection(bottom.extent), arguments: [top, bottom, p, q])
    }
    /// Maps luminance onto palette stops (gradient map), optionally keeping the original
    /// luminance (palette swap), mixed with the original by p.y.
    private static let mapKernel = CIColorKernel(source: """
        kernel vec4 meldMap(__sample s, vec4 c0, vec4 c1, vec4 c2, vec4 c3, vec4 p) {
            vec3 w = vec3(0.2126, 0.7152, 0.0722);
            float ls = max(dot(s.rgb, w), 0.0);
            float x = clamp(pow(ls, 0.4545), 0.0, 1.0) * p.x;
            vec3 g;
            if (x < 1.0) { g = mix(c0.rgb, c1.rgb, x); }
            else if (x < 2.0) { g = mix(c1.rgb, c2.rgb, x - 1.0); }
            else { g = mix(c2.rgb, c3.rgb, min(x - 2.0, 1.0)); }
            if (p.z > 0.5) { g = clamp(g + (ls - dot(g, w)), 0.0, 1.0); }
            return vec4(mix(s.rgb, g, p.y), s.a);
        }
        """)!
    /// Rounds perceptual luminance to `p.x` bands, scaling each pixel's colour to its band.
    private static let valueKernel = CIColorKernel(source: """
        kernel vec4 meldValues(__sample s, vec2 p) {
            float l = max(dot(s.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
            float q = floor(pow(l, 0.4545) * p.x + 0.5) / p.x;
            return vec4(clamp(s.rgb * (pow(q, 2.2) / l), 0.0, 1.0), s.a);
        }
        """)!
    private static func linear(_ ink: Ink) -> CIVector {
        func f(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return CIVector(x: f(ink.r), y: f(ink.g), z: f(ink.b), w: 1)
    }
    /// Whole-composite stages: mirror symmetry, a directional or zoom blur partly mixed in,
    /// then a colour treatment. Blurs and mirrors sample the edge-clamped composite, so no
    /// border or transparency enters.
    static func effects(_ e: Effects, on input: CIImage, rect: CGRect, focus: CIVector) -> CIImage {
        var composite = input
        let w = rect.width, h = rect.height, long = max(w, h)
        if e.symmetry != .none {
            // Reflect the larger side onto the smaller across a whole-pixel axis: plain crops
            // and an exact reflection, which Core Image tiles cheaply, with no seam or border.
            func reflect(_ image: CIImage, vertical: Bool) -> CIImage {
                let axis = vertical ? (w * e.splitX).rounded() : (h * (1 - e.splitY)).rounded()
                let size = vertical ? w : h
                let keepLow = axis >= size / 2
                func span(_ from: CGFloat, _ to: CGFloat) -> CGRect {
                    vertical ? CGRect(x: from, y: 0, width: to - from, height: h) : CGRect(x: 0, y: from, width: w, height: to - from)
                }
                let kept = image.cropped(to: keepLow ? span(0, axis) : span(axis, size))
                let flip = vertical ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * axis, ty: 0)
                                    : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * axis)
                let mirrored = kept.clampedToExtent().transformed(by: flip).cropped(to: keepLow ? span(axis, size) : span(0, axis))
                return mirrored.composited(over: kept).cropped(to: rect)
            }
            if e.symmetry != .horizontal { composite = reflect(composite, vertical: true) }
            if e.symmetry != .vertical { composite = reflect(composite, vertical: false) }
        }
        if e.blur != .none, e.blurAmount > 0.0001, e.blurMix > 0.001 {
            // Blur at most 800 pixels across and enlarge the result: a blurred field looks the
            // same, while full-size 2400-pixel blurs held hundreds of MB.
            let f = min(1, 800 / long)
            let amount = min(0.1, e.blurAmount) * long * f
            // A soft pre-blur turns streaks of fine detail into smooth fields of colour.
            let small = composite.clampedToExtent().transformed(by: CGAffineTransform(scaleX: f, y: f))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, long * f * 0.006)])
            let blurredSmall = e.blur == .motion
                ? small.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: amount, kCIInputAngleKey: e.blurAngle * .pi / 180])
                : small.applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: focus.x * f, y: focus.y * f), "inputAmount": amount])
            // Whole pixels, rounded up: the reduced canvas is rarely an integral size (a 2400-pixel
            // landscape is 571.4 high at this scale), and a partial last row would blend in empty pixels.
            let blurred = blurredSmall.cropped(to: CGRect(x: 0, y: 0, width: (w * f).rounded(.up), height: (h * f).rounded(.up))).clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 1 / f, y: 1 / f))
            composite = composite.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blurred.cropped(to: rect), kCIInputTimeKey: min(1, e.blurMix)]).cropped(to: rect)
        }
        let mix = min(1, max(0, e.colourMix))
        if mix > 0.001 {
            switch e.colour {
            case .none: break
            case .gradientMap, .paletteSwap:
                guard e.colours.count >= 2 else { break }
                let stops = Array(e.colours.prefix(4)).map(linear)
                let padded = stops + Array(repeating: stops.last!, count: 4 - stops.count)
                let p = CIVector(x: Double(stops.count - 1), y: mix, z: e.colour == .paletteSwap ? 1 : 0, w: 0)
                if let mapped = mapKernel.apply(extent: rect, arguments: [composite] + padded + [p]) { composite = mapped }
            case .posterize:
                // Value bands after a slight smoothing: flat shapes in each area's own colour,
                // without per-channel posterize's speckle and stray hues.
                let smooth = composite.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, long * 0.003)]).cropped(to: rect)
                guard let posterized = valueKernel.apply(extent: rect, arguments: [smooth, CIVector(x: Double(max(2, e.levels)), y: 0)]) else { break }
                composite = composite.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: posterized, kCIInputTimeKey: mix]).cropped(to: rect)
            case .hue:
                composite = composite.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: e.hue * mix * .pi / 180]).cropped(to: rect)
            }
        }
        return composite
    }
    /// Fine grey grain as a surface texture, about one cell per 1200th of the long edge.
    static func grain(_ e: Effects, over composite: CIImage, rect: CGRect) -> CIImage {
        let cell = max(1, max(rect.width, rect.height) / 1200)
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return composite }
        let noise = random.transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(0.3, e.grain))])
            .cropped(to: rect)
        return noise.applyingFilter(e.grainBlend.filter, parameters: [kCIInputBackgroundImageKey: composite]).cropped(to: rect)
    }
    /// Maps the plane onto one cell, mirroring alternate repeats. Samples stay within the
    /// cell's edge pixel centres, so a resampled cell edge never lets the background through.
    private static let mirrorTile = CIWarpKernel(source:
        "kernel vec2 mirrorTile(vec2 size) { vec2 q = mod(destCoord(), 2.0 * size); return clamp(size - abs(q - size), vec2(0.5), size - 0.5); }")!
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
            // Keep the same logical noise cells at thumbnail, preview, and export sizes.
            noise(l, into: ctx, cell: step / 8)
        case .image: break
        }
        return ctx.makeImage()
    }
    /// Square cells of seeded mixes between paper and ink, filled in order over the paper as
    /// anti-aliased Core Graphics rectangles would be, but written straight into the bitmap.
    /// Filling up to 230,000 cells one call at a time took up to a second per preview. Core
    /// Graphics still converts the 1000 possible colours; partially covered edge pixels follow
    /// its coverage and blending to within one level.
    private static func noise(_ l: Layer, into ctx: CGContext, cell: Double) {
        let w = ctx.width, h = ctx.height, stride = ctx.bytesPerRow
        guard cell > 0, let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self), let palette = canvas(w: 1000, h: 1),
              let colours = palette.data?.assumingMemoryBound(to: UInt8.self) else { return }
        for i in 0..<1000 {
            let v = Double(i) / 999
            palette.setFillColor(CGColor(red: l.paper.r * (1-v) + l.ink.r*v, green: l.paper.g*(1-v)+l.ink.g*v, blue: l.paper.b*(1-v)+l.ink.b*v, alpha: 1))
            palette.fill(CGRect(x: i, y: 0, width: 1, height: 1))
        }
        // Cell edges in 1/256 pixel, as Core Graphics snaps them.
        func snap(_ v: Double) -> Int { Int((v * 256).rounded()) }
        let rows = Int(ceil(Double(h) / cell)), columns = Int(ceil(Double(w) / cell))
        let lows = (0..<max(rows, columns)).map { snap(Double($0) * cell) }
        let highs = (0..<max(rows, columns)).map { snap(Double($0) * cell + cell) }
        var seed: UInt64 = 812367
        for y in 0..<rows {
            let ya = lows[y], yb = highs[y]
            for x in 0..<columns {
                seed = seed &* 6364136223846793005 &+ 1
                let colour = colours + Int((seed >> 33) % 1000) * 4
                let xa = lows[x], xb = highs[x]
                for py in (ya >> 8)..<min(h, (yb + 255) >> 8) {
                    let cy = min(yb, (py + 1) << 8) - max(ya, py << 8)
                    guard cy > 0 else { continue }
                    // Bitmap rows run from the top; cell rows from the bottom.
                    let row = pixels + (h - 1 - py) * stride
                    for px in (xa >> 8)..<min(w, (xb + 255) >> 8) {
                        let cx = min(xb, (px + 1) << 8) - max(xa, px << 8)
                        guard cx > 0 else { continue }
                        let coverage = (cx * cy + 128) >> 8, p = row + px * 4
                        if coverage >= 256 { p[0] = colour[0]; p[1] = colour[1]; p[2] = colour[2]; continue }
                        let a = 255 * coverage / 256
                        for c in 0..<3 { p[c] = UInt8((Int(colour[c]) * a + Int(p[c]) * (255 - a)) / 255) }
                    }
                }
            }
        }
    }
    static func waveMap(w: Int, h: Int, frequency: Double) -> CIImage? {
        // A small displacement map scales smoothly at preview and export sizes.
        // Core Image enlarges it during the render; a CPU-side full-size copy cost
        // about 35 ms and 23 MB per 2400-pixel image.
        let mw = 256, mh = max(1, Int(256 * Double(h) / Double(w)))
        guard let ctx = canvas(w: mw, h: mh), let buffer = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<mh { for x in 0..<mw {
            let u = Double(x) / Double(mw), v = Double(y) / Double(mh)
            let i = y * ctx.bytesPerRow + x * 4
            buffer[i] = UInt8((0.5 + 0.48 * sin(v * frequency * .pi * 2 + u * 2)) * 255)
            buffer[i+1] = UInt8((0.5 + 0.48 * cos(u * frequency * .pi * 2 + v * 3)) * 255)
            buffer[i+2] = 128; buffer[i+3] = 255
        }}
        return ctx.makeImage().map { small in
            CIImage(cgImage: small).clampedToExtent().transformed(by: CGAffineTransform(scaleX: Double(w) / Double(mw), y: Double(h) / Double(mh)))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
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
