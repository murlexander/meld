import AppKit
import ImageIO

final class CancellableJob {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

struct Trial: Identifiable {
    let id = UUID()
    /// Session-wide number; unique across sets so exported file names never collide.
    var number: Int
    /// The set or variation group this preview belongs to.
    var group = 0
    let style: CompositionStyle
    let original: Artwork
    var art: Artwork
    var thumbnail: CGImage
    var refinement = Refinement()
    var adjusted: Bool { art != original }
    var title: String { String(format: "%02d", number) + " · " + style.rawValue }
    init(number: Int, style: CompositionStyle, art: Artwork, thumbnail: CGImage) {
        self.number = number; self.style = style; self.original = art; self.art = art; self.thumbnail = thumbnail
    }
}

/// A row of previews in the grid: one generated set, or variations of one preview.
struct TrialGroup: Identifiable, Equatable {
    let id: Int
    let title: String
}

struct Refinement: Equatable {
    var distortion = 1.0
    var pattern = 1.0
}

enum SessionStage { case material, previews, refine }

enum CompositionStyle: String, CaseIterable {
    case flow = "Flow", vortex = "Vortex", blocks = "Blocks"
    case detail = "Detail", tiles = "Tiles"
}

/// Geometry of the Renderer's layer transform, in canvas-height units. An image layer is
/// cover-fitted at scale 1, centred at `(0.5 + x, 0.5 - y)` of the canvas and rotated by
/// `rotation` degrees, so scale 1 with no rotation or offset exactly fills the canvas.
enum Coverage {
    /// Generated layers keep this much extra scale beyond exact coverage, absorbing pixel
    /// rounding of canvas sizes and resampling at the image boundary.
    static let margin = 1.02
    /// Smallest `layer.scale` at which the rotated, offset layer covers the whole canvas.
    static func minimumCoverScale(canvasAspect r: Double, imageAspect k: Double, rotation: Double, x: Double, y: Double) -> Double {
        // Size of the image at scale 1, and its centre relative to the canvas centre.
        let width = max(r, k), height = max(r / k, 1)
        let cx = r * x, cy = -y
        let angle = rotation * .pi / 180, c = cos(angle), s = sin(angle)
        var needed = 0.0
        for (px, py) in [(-r/2, -0.5), (r/2, -0.5), (-r/2, 0.5), (r/2, 0.5)] {
            // Each canvas corner, in the image's own (unrotated) axes.
            let dx = px - cx, dy = py - cy
            let u = c * dx + s * dy, v = -s * dx + c * dy
            needed = max(needed, 2 * abs(u) / width, 2 * abs(v) / height)
        }
        return needed
    }
    static func covers(canvasAspect r: Double, imageAspect k: Double, scale: Double, rotation: Double, x: Double, y: Double) -> Bool {
        minimumCoverScale(canvasAspect: r, imageAspect: k, rotation: rotation, x: x, y: y) <= scale + 1e-9
    }
    /// Width over height of what the Renderer draws for a layer: the image, or a canvas-sized pattern.
    static func aspect(of layer: Layer, canvas ratio: Double) -> Double {
        guard layer.material == .image else { return ratio }
        guard let pixels = layer.image?.pixels, pixels.height > 0 else { return 1 }
        return Double(pixels.width) / Double(pixels.height)
    }
    /// Whether a layer is placed geometrically; mirrored tiles already repeat endlessly.
    static func applies(to layer: Layer) -> Bool { layer.material != .image || layer.tiles <= 1 }
    /// Makes a layer cover the canvas with `margin` to spare, keeping its rotation. It keeps
    /// at least the requested scale and pulls the offset towards the centre as far as needed;
    /// it only zooms further when even a centred layer would not cover.
    static func fill(_ layer: inout Layer, canvas ratio: Double) {
        guard applies(to: layer) else { return }
        let k = aspect(of: layer, canvas: ratio)
        func needed(_ t: Double) -> Double {
            margin * minimumCoverScale(canvasAspect: ratio, imageAspect: k, rotation: layer.rotation, x: layer.x * t, y: layer.y * t)
        }
        let scale = max(layer.scale, needed(0))
        // Allowed centres form a convex region containing the canvas centre, so
        // shrinking the offset along its line finds the farthest covering position.
        var t = 1.0
        if needed(1) > scale {
            var low = 0.0, high = 1.0
            for _ in 0..<40 { let mid = (low + high) / 2; if needed(mid) <= scale { low = mid } else { high = mid } }
            t = low
        }
        layer.scale = scale; layer.x *= t; layer.y *= t
    }
}

// A seed describes a repeatable recipe, independent of layer UUIDs.
struct RecipeRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    mutating func value(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / 9007199254740992 * (range.upperBound - range.lowerBound)
    }
    mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
}

struct PreparedMaterial {
    let layer: Layer
    let colours: [Ink]
    init(_ layer: Layer) {
        self.layer = layer
        colours = SourcePalette.colours(layer.image)
    }
}

enum SourcePalette {
    static func colours(_ source: SourceImage?) -> [Ink] {
        let fallback = [Ink(0.12, 0.2, 0.27), Ink(0.7, 0.4, 0.25), Ink(0.9, 0.85, 0.73)]
        guard let image = source?.thumbnail else { return fallback }
        return cluster(image, count: 4) ?? fallback
    }
    /// Main colours of a rendered preview, dark to light, for painting references.
    static func colours(of image: CGImage, count: Int = 5) -> [Ink] {
        cluster(image, count: count) ?? []
    }
    private static func cluster(_ image: CGImage, count: Int) -> [Ink]? {
        guard let context = Renderer.canvas(w: 24, h: 24),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(Ink(0.94, 0.92, 0.87).cg)
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        let samples = stride(from: 0, to: 24 * 24 * 4, by: 4).map { i in
            Ink(Double(pixels[i]) / 255, Double(pixels[i+1]) / 255, Double(pixels[i+2]) / 255)
        }
        func distance(_ a: Ink, _ b: Ink) -> Double {
            pow(a.r-b.r, 2) + pow(a.g-b.g, 2) + pow(a.b-b.b, 2)
        }
        // Farthest-first centres preserve small colour accents instead of averaging to grey.
        var centres = [samples[0]]
        for _ in 1..<count {
            centres.append(samples.max { a, b in
                centres.map { distance(a, $0) }.min()! < centres.map { distance(b, $0) }.min()!
            }!)
        }
        for _ in 0..<6 {
            var groups = Array(repeating: [Ink](), count: count)
            for sample in samples {
                let nearest = centres.indices.min { distance(sample, centres[$0]) < distance(sample, centres[$1]) }!
                groups[nearest].append(sample)
            }
            for i in groups.indices where !groups[i].isEmpty {
                let group = groups[i], n = Double(group.count)
                centres[i] = Ink(group.reduce(0) { $0+$1.r }/n, group.reduce(0) { $0+$1.g }/n, group.reduce(0) { $0+$1.b }/n)
            }
        }
        return centres.sorted { $0.luminance < $1.luminance }
    }
}

extension Ink {
    var luminance: Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }
    func mixed(with other: Ink, amount: Double) -> Ink {
        Ink(r * (1-amount) + other.r * amount, g * (1-amount) + other.g * amount, b * (1-amount) + other.b * amount)
    }
}

enum TrialGenerator {
    /// Generated patterns are only a subtle texture: the photographs must clearly dominate.
    static let patternOpacityCap = 0.3
    static let patternBlends: [Blend] = [.softLight, .multiply]
    /// Shapes variations may swap in; bold stripes overpower the photographs.
    static let patternShapes: [Material] = [.dots, .checker, .rings, .noise]
    static func styles(count: Int, seed: UInt64) -> [CompositionStyle] {
        var random = RecipeRandom(seed: seed)
        // Each group of six explores every style plus one extra, and the extras rotate
        // through the styles, so a batch never becomes twenty similar swirls.
        var result: [CompositionStyle] = [], extras: [CompositionStyle] = []
        while result.count < count {
            if extras.isEmpty { extras = CompositionStyle.allCases.shuffled(using: &random) }
            result += (CompositionStyle.allCases + [extras.removeFirst()]).shuffled(using: &random)
        }
        return Array(result.prefix(count))
    }
    static func compose(_ materials: [PreparedMaterial], style: CompositionStyle, aspect: String, seed: UInt64) -> Artwork {
        var random = RecipeRandom(seed: seed)
        var art = Artwork(); art.aspect = aspect
        guard !materials.isEmpty else { return art }
        let picked = Array(materials.shuffled(using: &random).prefix(min(materials.count, random.pick([2, 3]))))
        let colours = picked[0].colours
        let paper = colours.last!.mixed(with: Ink(0.98, 0.96, 0.91), amount: 0.5)
        let colour = random.pick(colours)
        art.background = paper
        let ratio = art.ratio
        art.layers = picked.map { prepared in
            var layer = prepared.layer
            layer.id = UUID(); layer.visible = true; layer.tiles = 1
            place(&layer, ratio: ratio, zoom: zoom(&random), random: &random)
            return layer
        }
        for i in art.layers.indices where i > 0 {
            art.layers[i].opacity = random.value(0.2...0.45)
            art.layers[i].blend = random.pick([.softLight, .screen, .normal])
        }
        func pattern(_ shape: Material, _ opacity: Double, _ blend: Blend, _ frequency: Double, _ rotation: Double) -> Layer {
            var layer = Layer(name: shape.label, material: shape, opacity: min(opacity, patternOpacityCap), blend: blend, scale: 1.5,
                              rotation: rotation, frequency: frequency, ink: colour, paper: paper)
            // Rotated canvas-sized patterns need more than 1.5× on non-square canvases.
            Coverage.fill(&layer, canvas: ratio)
            return layer
        }
        art.warp.centerX = random.value(0.3...0.7); art.warp.centerY = random.value(0.3...0.7)
        art.warp.saturation = random.value(0.8...1.25)
        switch style {
        case .flow:
            art.layers.append(pattern(random.pick([.dots, .noise]), random.value(0.12...0.26), .softLight, random.value(4...17), random.value(-80...80)))
            art.warp.wave = random.value(0.17...0.4); art.warp.wavelength = random.value(1.4...4.5)
            art.warp.twist = random.value(-0.4...0.4)
        case .vortex:
            art.layers.append(pattern(.rings, random.value(0.14...0.28), .softLight, random.value(4...12), 0))
            art.warp.twist = random.pick([-1.0, 1.0]) * random.value(1.2...2.7)
            art.warp.bulge = random.value(-0.25...0.4); art.warp.wave = random.value(0...0.08)
        case .blocks:
            place(&art.layers[0], ratio: ratio, zoom: random.value(1.6...2.8), random: &random)
            art.layers.append(pattern(.checker, random.value(0.1...0.24), .softLight, random.value(3...9), random.pick([0, 45])))
            art.warp.pixel = random.value(0.45...0.95); art.warp.contrast = random.value(1.02...1.18)
        case .detail:
            // One strongly zoomed, turned crop dominates; the others glaze over it full-bleed,
            // finished with a fine grain.
            place(&art.layers[0], ratio: ratio, zoom: random.value(2.2...3.6), random: &random)
            for i in art.layers.indices where i > 0 {
                art.layers[i].opacity = random.value(0.18...0.4)
                art.layers[i].blend = random.pick([.softLight, .multiply, .screen, .normal])
            }
            art.warp.wave = random.pick([0, random.value(0.02...0.06)]); art.warp.wavelength = random.value(1.5...3)
            art.warp.contrast = random.value(1...1.12)
            art.layers.append(pattern(.noise, random.value(0.08...0.18), .softLight, random.value(30...60), 0))
        case .tiles:
            art.layers[0].tiles = random.pick([3, 4, 5, 6]); art.layers[0].scale = random.value(0.9...1.2)
            art.layers[0].rotation = random.pick([0, 30, 45, 90])
            for i in art.layers.indices where i > 0 { art.layers[i].tiles = art.layers[0].tiles; art.layers[i].opacity = 0.2 }
            art.layers.append(pattern(random.pick([.dots, .noise]), 0.16, .softLight, random.value(6...18), 0))
            art.warp.wave = random.value(0...0.08)
        }
        return art
    }

    /// Zoom over exact coverage: a quarter are plain covering crops, half a moderate
    /// zoom, and a quarter a strong detail crop.
    static func zoom(_ random: inout RecipeRandom) -> Double {
        let roll = random.value(0...1)
        return roll < 0.25 ? 1 : roll < 0.75 ? random.value(1.15...1.8) : random.value(2...3.4)
    }
    /// Any angle occurs; small tilts and quarter turns are a little more likely than chance.
    static func angle(_ random: inout RecipeRandom) -> Double {
        let roll = random.value(0...1)
        if roll < 0.3 { return random.value(-15...15) }
        if roll < 0.45 { return random.pick([90.0, 180, -90]) + random.value(-8...8) }
        return random.value(-180...180)
    }
    /// Full-bleed placement: a random rotation, `zoom` over the scale that covers the canvas
    /// at that rotation, and a random point of the image moved near the canvas centre. The
    /// offset is then pulled back as far as needed for the canvas to stay covered. Total scale
    /// stays at most 4× unless coverage needs more, which a 2400-pixel source supports.
    static func place(_ layer: inout Layer, ratio: Double, zoom: Double, random: inout RecipeRandom) {
        let k = Coverage.aspect(of: layer, canvas: ratio)
        layer.rotation = angle(&random)
        let cover = Coverage.margin * Coverage.minimumCoverScale(canvasAspect: ratio, imageAspect: k, rotation: layer.rotation, x: 0, y: 0)
        layer.scale = max(cover, min(4, cover * zoom))
        // A focus point in the image, in canvas-height units relative to the image centre.
        let width = max(ratio, k) * layer.scale, height = max(ratio / k, 1) * layer.scale
        let u = random.value(-0.5...0.5) * width, v = random.value(-0.5...0.5) * height
        let angle = layer.rotation * .pi / 180
        let fx = cos(angle) * u - sin(angle) * v, fy = sin(angle) * u + cos(angle) * v
        // Centre the image so that point lands on the canvas centre (y runs downwards in the model).
        layer.x = -fx / ratio; layer.y = fy
        Coverage.fill(&layer, canvas: ratio)
    }

    /// A relative of a preview: the same recipe and images with nudged placement, pattern
    /// and distortion. `amount` runs from close (0.5) to bold (2); bolder relatives may swap
    /// in another image from the session, change a pattern shape or a blend.
    static func vary(_ base: Artwork, materials: [PreparedMaterial], seed: UInt64, amount: Double = 1) -> Artwork {
        var random = RecipeRandom(seed: seed)
        let a = min(2, max(0.25, amount))
        func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
        func nudge(_ v: Double, _ spread: Double) -> Double { let s = min(0.9, spread * a); return v * random.value((1 - s)...(1 + s)) }
        func shift(_ spread: Double) -> Double { random.value(-spread * a...spread * a) }
        func chance(_ p: Double) -> Bool { random.value(0...1) < p * a }
        var art = base
        let palette = materials.flatMap(\.colours)
        for i in art.layers.indices {
            var layer = art.layers[i]
            layer.id = UUID()
            layer.scale = clamp(nudge(layer.scale, 0.2), 0.1...4)
            layer.rotation = clamp(layer.rotation + shift(layer.material == .image ? 30 : 15), -180...180)
            layer.x = clamp(layer.x + shift(0.1), -0.75...0.75)
            layer.y = clamp(layer.y + shift(0.1), -0.75...0.75)
            if layer.material == .image {
                if i > 0 {
                    layer.opacity = clamp(layer.opacity + shift(0.12), 0.1...1)
                    if chance(0.15) { layer.blend = random.pick([.softLight, .screen, .normal, .multiply]) }
                }
            } else {
                layer.frequency = clamp(nudge(layer.frequency, 0.35), 2...60)
                layer.rotation = clamp(layer.rotation + shift(25), -180...180)
                layer.opacity = clamp(layer.opacity + shift(0.06), 0.05...patternOpacityCap)
                if !patternBlends.contains(layer.blend) { layer.blend = .softLight }
                if !palette.isEmpty && chance(0.3) { layer.ink = random.pick(palette) }
                if chance(0.12) || layer.material == .stripes {
                    layer.material = random.pick(patternShapes)
                    layer.name = layer.material.label
                }
            }
            art.layers[i] = layer
        }
        let imageIndices = art.layers.indices.filter { art.layers[$0].material == .image }
        let fresh = materials.filter { material in !art.layers.contains { $0.image === material.layer.image } }
        if !imageIndices.isEmpty, !fresh.isEmpty, chance(0.25) {
            let target = random.pick(imageIndices), replacement = random.pick(fresh).layer
            art.layers[target].image = replacement.image
            art.layers[target].sourcePath = replacement.sourcePath
            art.layers[target].name = replacement.name
        }
        // Variations stay full-bleed, even when nudged or given an image of another shape.
        for i in art.layers.indices { Coverage.fill(&art.layers[i], canvas: art.ratio) }
        var warp = art.warp
        warp.wave = clamp(nudge(warp.wave, 0.35), 0...1)
        warp.wavelength = clamp(nudge(warp.wavelength, 0.3), 1...12)
        warp.twist = clamp(nudge(warp.twist, 0.35), -5...5)
        warp.bulge = clamp(nudge(warp.bulge, 0.35), -0.9...0.9)
        warp.pixel = clamp(nudge(warp.pixel, 0.3), 0...1)
        warp.centerX = clamp(warp.centerX + shift(0.15), 0...1)
        warp.centerY = clamp(warp.centerY + shift(0.15), 0...1)
        warp.saturation = clamp(warp.saturation + shift(0.15), 0...2)
        art.warp = warp
        return art
    }

    static func contactSheet(_ trials: [Trial]) -> Data? {
        guard !trials.isEmpty else { return nil }
        let columns = min(4, trials.count), cell = 300, row = 328
        let rows = (trials.count + columns - 1) / columns
        guard let context = Renderer.canvas(w: columns * cell, h: rows * row) else { return nil }
        context.setFillColor(Ink(0.95, 0.94, 0.9).cg)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (i, trial) in trials.enumerated() {
            let x = i % columns * cell, y = (rows - 1 - i / columns) * row
            let ratio = trial.art.ratio, edge = Double(cell - 20)
            let w = ratio >= 1 ? edge : edge * ratio, h = ratio >= 1 ? edge / ratio : edge
            context.draw(trial.thumbnail, in: CGRect(x: Double(x) + (Double(cell)-w)/2, y: Double(y) + 30 + (edge-h)/2, width: w, height: h))
            (trial.title as NSString).draw(at: CGPoint(x: x + 10, y: y + 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray])
            // A small palette strip turns the sheet into a painting reference.
            for (j, ink) in SourcePalette.colours(of: trial.thumbnail).reversed().enumerated() {
                context.setFillColor(ink.cg)
                context.fill(CGRect(x: x + cell - 24 - j * 16, y: y + 8, width: 14, height: 14))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
