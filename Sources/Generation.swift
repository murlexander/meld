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
    let number: Int
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

struct Refinement: Equatable {
    var distortion = 1.0
    var pattern = 1.0
}

enum SessionStage { case material, previews, refine }

enum CompositionStyle: String, CaseIterable {
    case flow = "Flow", vortex = "Vortex", blocks = "Blocks"
    case collage = "Collage", weave = "Weave", tiles = "Tiles"
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
        guard let image = source?.thumbnail,
              let context = Renderer.canvas(w: 24, h: 24),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return fallback }
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
        for _ in 1..<4 {
            centres.append(samples.max { a, b in
                centres.map { distance(a, $0) }.min()! < centres.map { distance(b, $0) }.min()!
            }!)
        }
        for _ in 0..<6 {
            var groups = Array(repeating: [Ink](), count: 4)
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
    static func styles(count: Int, seed: UInt64) -> [CompositionStyle] {
        var random = RecipeRandom(seed: seed)
        // Each group explores every style; a batch never becomes twenty similar swirls.
        var result: [CompositionStyle] = []
        while result.count < count { result += CompositionStyle.allCases.shuffled(using: &random) }
        return Array(result.prefix(count))
    }
    static func compose(_ materials: [PreparedMaterial], style: CompositionStyle, aspect: String, seed: UInt64) -> Artwork {
        var random = RecipeRandom(seed: seed)
        var art = Artwork(); art.aspect = aspect
        guard !materials.isEmpty else { return art }
        let picked = Array(materials.shuffled(using: &random).prefix(min(materials.count, random.pick([2, 3]))))
        let colours = picked[0].colours
        let ink = colours[0].mixed(with: Ink(0.04, 0.06, 0.07), amount: 0.15)
        let paper = colours.last!.mixed(with: Ink(0.98, 0.96, 0.91), amount: 0.5)
        let colour = random.pick(colours)
        art.background = paper
        art.layers = picked.map { prepared in
            var layer = prepared.layer
            layer.id = UUID(); layer.visible = true; layer.tiles = 1
            layer.scale = random.value(1.15...1.7); layer.rotation = random.value(-18...18)
            layer.x = random.value(-0.18...0.18); layer.y = random.value(-0.18...0.18)
            return layer
        }
        for i in art.layers.indices where i > 0 {
            art.layers[i].opacity = random.value(0.2...0.45)
            art.layers[i].blend = random.pick([.softLight, .screen, .normal])
        }
        func pattern(_ shape: Material, _ opacity: Double, _ blend: Blend, _ frequency: Double, _ rotation: Double) -> Layer {
            Layer(name: shape.label, material: shape, opacity: opacity, blend: blend, scale: 1.5,
                  rotation: rotation, frequency: frequency, ink: colour, paper: paper)
        }
        art.warp.centerX = random.value(0.3...0.7); art.warp.centerY = random.value(0.3...0.7)
        art.warp.saturation = random.value(0.8...1.25)
        switch style {
        case .flow:
            art.layers.append(pattern(random.pick([.stripes, .noise]), random.value(0.16...0.35), .softLight, random.value(4...17), random.value(-80...80)))
            art.warp.wave = random.value(0.17...0.4); art.warp.wavelength = random.value(1.4...4.5)
            art.warp.twist = random.value(-0.4...0.4)
        case .vortex:
            art.layers.append(pattern(.rings, random.value(0.2...0.45), .softLight, random.value(4...12), 0))
            art.warp.twist = random.pick([-1.0, 1.0]) * random.value(1.2...2.7)
            art.warp.bulge = random.value(-0.25...0.4); art.warp.wave = random.value(0...0.08)
        case .blocks:
            art.layers[0].scale = random.value(1.6...2.8)
            art.layers.append(pattern(.checker, random.value(0.12...0.32), .softLight, random.value(3...9), random.pick([0, 45])))
            art.warp.pixel = random.value(0.45...0.95); art.warp.contrast = random.value(1.02...1.18)
        case .collage:
            for i in art.layers.indices {
                art.layers[i].scale = random.value(0.42...0.74)
                art.layers[i].rotation = random.value(-28...28)
                art.layers[i].x = i == 0 ? -0.22 : (i == 1 ? 0.23 : random.value(-0.1...0.1))
                art.layers[i].y = i == 0 ? 0.18 : (i == 1 ? -0.16 : random.value(-0.25...0.25))
                art.layers[i].blend = .normal; art.layers[i].opacity = random.value(0.8...1)
            }
            var ground = pattern(random.pick([.stripes, .dots]), 0.4, .normal, random.value(3...8), random.value(-30...30))
            ground.ink = ink
            art.layers.insert(ground, at: 0)
        case .weave:
            art.layers.append(pattern(random.pick([.stripes, .dots, .checker]), random.value(0.6...0.82), .normal, random.value(5...22), random.pick([0, 30, 45, 90])))
            var crossing = pattern(.stripes, random.value(0.2...0.4), .multiply, random.value(3...12), random.pick([-45, 0, 90]))
            crossing.ink = ink
            art.layers.append(crossing)
            art.warp.wave = random.value(0...0.1); art.warp.wavelength = random.value(1.5...3)
        case .tiles:
            art.layers[0].tiles = random.pick([3, 4, 5, 6]); art.layers[0].scale = random.value(0.9...1.2)
            art.layers[0].rotation = random.pick([0, 30, 45, 90])
            for i in art.layers.indices where i > 0 { art.layers[i].tiles = art.layers[0].tiles; art.layers[i].opacity = 0.2 }
            art.layers.append(pattern(random.pick([.dots, .stripes]), 0.16, .softLight, random.value(6...18), 0))
            art.warp.wave = random.value(0...0.08)
        }
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
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
