import Foundation

/// Independent stages layered on a style's base geometry, one choice per family. They push a
/// preview towards a painting idea: simpler value and colour shapes, overlapping photographs,
/// symmetry and stretched or blurred colour fields.
struct StagePlan: Hashable {
    enum Geometry: String, CaseIterable { case none, mirror, stretch }
    enum Layering: String, CaseIterable { case none, luminosity, fade, echo, blend }
    enum Colour: String, CaseIterable { case none, gradientMap, paletteSwap, posterize, hue }
    enum Surface: String, CaseIterable { case none, motionBlur, zoomBlur, grain }
    var geometry = Geometry.none
    var layering = Layering.none
    var colour = Colour.none
    var surface = Surface.none

    /// Chance of each stage in an ordinary (not quiet) preview; the rest of each family is "none".
    static let geometryOdds: [(Geometry, Double)] = [(.mirror, 0.25), (.stretch, 0.2)]
    static let layeringOdds: [(Layering, Double)] = [(.luminosity, 0.25), (.fade, 0.22), (.echo, 0.12), (.blend, 0.16)]
    static let colourOdds: [(Colour, Double)] = [(.gradientMap, 0.24), (.paletteSwap, 0.18), (.posterize, 0.14), (.hue, 0.12)]
    static let surfaceOdds: [(Surface, Double)] = [(.motionBlur, 0.2), (.zoomBlur, 0.08), (.grain, 0.12)]
    /// Share of quiet previews: one per group of six, plus this chance for the others.
    static let extraQuiet = 0.05
    /// At most this many strong stages and this much total intensity per preview.
    static let strongLimit = 2
    static let weightLimit = 3.0

    var names: [String] {
        [geometry.rawValue, layering.rawValue, colour.rawValue, surface.rawValue].filter { $0 != "none" }
    }
    var count: Int { names.count }
    /// Stages that change a preview most: strong ones count 1, medium ones a half, fine ones nothing.
    static let strong: Set<String> = ["mirror", "stretch", "luminosity", "gradientMap", "posterize", "motionBlur", "zoomBlur", "blendWild", "hueLarge"]
    static let medium: Set<String> = ["fade", "echo", "blend", "paletteSwap"]
    static func weight(_ names: [String]) -> Double {
        names.reduce(0) { $0 + (strong.contains($1) ? 1 : medium.contains($1) ? 0.5 : 0) }
    }
    var strongCount: Int { names.filter(Self.strong.contains).count }
    /// Families on which two plans make the same (active) choice.
    func overlap(_ other: StagePlan) -> Int {
        zip(names(all: true), other.names(all: true)).filter { $0 == $1 && $0 != "none" }.count
    }
    private func names(all: Bool) -> [String] { [geometry.rawValue, layering.rawValue, colour.rawValue, surface.rawValue] }
}

extension RecipeRandom {
    mutating func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + $1.1 }
        var roll = value(0...total)
        for (item, weight) in items { roll -= weight; if roll <= 0 { return item } }
        return items.last!.0
    }
}

extension TrialGenerator {
    /// One stage plan. Quiet plans have exactly one stage; others have two to four within the budget.
    static func plan(_ random: inout RecipeRandom, quiet: Bool) -> StagePlan {
        func draw<T>(_ odds: [(T, Double)], none: T) -> T {
            random.weighted(odds + [(none, max(0, 1 - odds.reduce(0) { $0 + $1.1 }))])
        }
        var plan = StagePlan()
        if quiet {
            switch random.weighted([(0, 0.2), (1, 0.35), (2, 0.35), (3, 0.1)]) {
            case 0: plan.geometry = random.weighted(StagePlan.geometryOdds)
            case 1: plan.layering = random.weighted(StagePlan.layeringOdds)
            case 2: plan.colour = random.weighted(StagePlan.colourOdds)
            default: plan.surface = random.weighted(StagePlan.surfaceOdds)
            }
            return plan
        }
        for _ in 0..<200 {
            plan = StagePlan(geometry: draw(StagePlan.geometryOdds, none: .none), layering: draw(StagePlan.layeringOdds, none: .none),
                             colour: draw(StagePlan.colourOdds, none: .none), surface: draw(StagePlan.surfaceOdds, none: .none))
            if plan.count >= 2 && plan.strongCount <= StagePlan.strongLimit && StagePlan.weight(plan.names) <= StagePlan.weightLimit - 0.5 { return plan }
        }
        return StagePlan(layering: .fade, colour: .paletteSwap)
    }

    /// Stage plans for a whole set: no combination repeats within the set, previews in a group of
    /// six share at most one stage choice, and each group has at least one quiet preview.
    static func plans(count: Int, seed: UInt64) -> [StagePlan] {
        var random = RecipeRandom(seed: seed ^ 0x6a09e667f3bcc909)
        var result: [StagePlan] = [], used = Set<StagePlan>()
        while result.count < count {
            let start = result.count, quietSlot = Int(random.next() % 6)
            for slot in 0..<6 where result.count < count {
                let quiet = slot == quietSlot || random.value(0...1) < StagePlan.extraQuiet
                var best = StagePlan(), bestScore = Int.max
                for _ in 0..<60 {
                    let candidate = plan(&random, quiet: quiet)
                    let overlap = result[start...].map { candidate.overlap($0) }.max() ?? 0
                    let score = (used.contains(candidate) ? 10 : 0) + max(0, overlap - 1)
                    if score < bestScore { best = candidate; bestScore = score }
                    if score == 0 { break }
                }
                result.append(best); used.insert(best)
            }
        }
        return result
    }

    /// Applies a plan's stages to a composed recipe. `picked` are its photographs, base first.
    static func applyStages(_ plan: StagePlan, to art: inout Artwork, picked: [PreparedMaterial], materials: [PreparedMaterial], random: inout RecipeRandom) {
        // A wild blend is strong, so it only joins plans with room in the budget.
        let roomForWild = plan.strongCount < StagePlan.strongLimit
        switch plan.layering {
        case .none: break
        case .echo: addEcho(&art, random: &random)
        case .luminosity, .fade, .blend:
            let images = art.layers.indices.filter { art.layers[$0].material == .image }
            let target = images.count > 1 ? images[1 + Int(random.next() % UInt64(images.count - 1))] : addEcho(&art, random: &random)
            switch plan.layering {
            case .luminosity: luminosityMask(&art.layers[target], random: &random)
            case .fade: fade(&art.layers[target], random: &random)
            default: blend(&art.layers[target], wild: roomForWild, random: &random)
            }
        }
        switch plan.geometry {
        case .none: break
        case .mirror: mirror(&art.effects, random: &random)
        case .stretch:
            let images = art.layers.indices.filter { art.layers[$0].material == .image && $0 > 0 }
            let target = images.isEmpty || random.value(0...1) < 0.6 ? 0 : random.pick(images)
            stretch(&art.layers[target], ratio: art.ratio, random: &random)
        }
        let palette = picked.first?.colours ?? SourcePalette.colours(nil)
        let others = picked.dropFirst().map(\.colours) + materials.filter { m in !picked.contains { $0.layer.image === m.layer.image } }.map(\.colours)
        if let treatment = ColourTreatment(rawValue: plan.colour.rawValue), treatment != .none {
            colour(treatment, &art.effects, palette: palette, others: others, random: &random)
        }
        switch plan.surface {
        case .none: break
        case .motionBlur: blur(.motion, &art.effects, random: &random)
        case .zoomBlur: blur(.zoom, &art.effects, random: &random)
        case .grain: art.effects.grain = random.value(0.08...0.16); art.effects.grainBlend = random.pick([.softLight, .overlay])
        }
    }

    /// The base photograph again over itself, larger and turned: its own shapes become a second layer.
    @discardableResult static func addEcho(_ art: inout Artwork, random: inout RecipeRandom) -> Int {
        guard let base = art.layers.firstIndex(where: { $0.material == .image }) else { return 0 }
        var echo = art.layers[base]
        echo.id = UUID(); echo.name += " echo"; echo.tiles = 1; echo.mask = .none; echo.stretch = 1
        echo.rotation = angle(&random)
        echo.scale = min(4, max(1, art.layers[base].scale) * random.value(1.3...2.5))
        echo.x += random.value(-0.2...0.2); echo.y += random.value(-0.2...0.2)
        echo.opacity = random.value(0.3...0.55)
        echo.blend = random.weighted([(Blend.normal, 1), (.softLight, 1), (.screen, 0.8), (.multiply, 0.6), (.overlay, 1)])
        Coverage.fill(&echo, canvas: art.ratio)
        let index = (art.layers.lastIndex { $0.material == .image } ?? base) + 1
        art.layers.insert(echo, at: index)
        return index
    }
    /// Double exposure: the photograph appears only where the layers below are bright, or dark.
    static func luminosityMask(_ layer: inout Layer, random: inout RecipeRandom) {
        layer.mask = random.pick([.bright, .dark])
        layer.maskPosition = random.value(0.35...0.65); layer.maskSoftness = random.value(0.08...0.2)
        layer.opacity = random.value(0.75...1)
        layer.blend = random.weighted([(Blend.normal, 3), (.screen, 1)])
    }
    /// A broad, soft transition from the photographs below into this one.
    static func fade(_ layer: inout Layer, random: inout RecipeRandom) {
        if random.value(0...1) < 0.6 {
            layer.mask = .linear; layer.maskAngle = random.value(-180...180)
            layer.maskPosition = random.value(-0.15...0.15); layer.maskSoftness = random.value(0.15...0.35)
        } else {
            layer.mask = .radial; layer.maskX = random.value(0.3...0.7); layer.maskY = random.value(0.3...0.7)
            layer.maskPosition = random.value(0.18...0.38); layer.maskSoftness = random.value(0.1...0.25)
        }
        layer.opacity = random.value(0.8...1)
        layer.blend = random.weighted([(Blend.normal, 3), (.softLight, 1)])
    }
    static let structureBlends: [(Blend, Double)] = [(.overlay, 3), (.hardLight, 2), (.luminosity, 1.5), (.color, 2), (.colorBurn, 1.5)]
    static let wildBlends: [(Blend, Double)] = [(.difference, 1), (.exclusion, 1), (.colorDodge, 0.8)]
    /// A contrasting blend between photographs. Returns whether it picked a wild mode.
    @discardableResult static func blend(_ layer: inout Layer, wild: Bool, random: inout RecipeRandom) -> Bool {
        layer.mask = .none
        layer.blend = random.weighted(structureBlends + (wild ? wildBlends : []))
        let isWild = wildBlends.contains { $0.0 == layer.blend }
        layer.opacity = isWild ? random.value(0.3...0.55) : random.value(0.45...0.8)
        return isWild
    }
    static func mirror(_ effects: inout Effects, random: inout RecipeRandom) {
        effects.symmetry = random.weighted([(Symmetry.vertical, 0.45), (.horizontal, 0.3), (.both, 0.25)])
        effects.splitX = random.value(0.4...0.6); effects.splitY = random.value(0.4...0.6)
    }
    /// Pulls a photograph 1.5–3× along one direction, often horizontal or vertical, into bands of colour.
    static func stretch(_ layer: inout Layer, ratio: Double, random: inout RecipeRandom) {
        layer.stretch = random.value(1.5...3)
        layer.stretchAngle = wrap(random.value(0...1) < 0.5 ? random.pick([0.0, 90]) + random.value(-4...4) : random.value(-90...90), 90)
        // Keep the combined enlargement within what a 2400-pixel source supports.
        if Coverage.applies(to: layer) { layer.scale = min(layer.scale, max(1, 4.5 / layer.stretch)) }
        Coverage.fill(&layer, canvas: ratio)
    }
    /// Sets a colour treatment. Hue shifts stay small: a nudge to the palette, not a new one.
    static func colour(_ treatment: ColourTreatment, _ effects: inout Effects, palette: [Ink], others: [[Ink]], random: inout RecipeRandom) {
        effects.colour = treatment
        switch treatment {
        case .none: effects.colourMix = 0
        case .gradientMap:
            // Dark to light stops from the photograph's palette, stretched to a clear value range.
            let dark = palette.first!.mixed(with: Ink(0.02, 0.02, 0.03), amount: 0.35)
            let light = palette.last!.mixed(with: Ink(0.98, 0.96, 0.9), amount: 0.25)
            if random.value(0...1) < 0.5 { effects.colours = [dark, light] }
            else {
                let middle = !others.isEmpty && random.value(0...1) < 0.5 ? random.pick(others)[random.pick([1, 2])] : palette[random.pick([1, 2])]
                effects.colours = [dark, middle, light]
            }
            effects.colourMix = random.value(0...1) < 0.4 ? random.value(0.85...1) : random.value(0.45...0.75)
        case .paletteSwap:
            effects.colours = others.isEmpty ? palette.reversed() : random.pick(others)
            effects.colourMix = random.value(0.55...0.9)
        case .posterize:
            effects.levels = random.pick([4, 5, 6, 7]); effects.colourMix = random.value(0.4...0.8)
        case .hue:
            effects.hue = random.pick([-1.0, 1.0]) * random.value(8...25); effects.colourMix = 1
        }
    }
    static func blur(_ kind: BlurKind, _ effects: inout Effects, random: inout RecipeRandom) {
        effects.blur = kind
        if kind == .motion {
            effects.blurAmount = random.value(0.02...0.06)
            effects.blurAngle = random.value(0...1) < 0.5 ? random.pick([0.0, 90]) : random.value(-90...90)
            effects.blurMix = random.value(0.45...0.8)
        } else {
            effects.blurAmount = random.value(0.02...0.04); effects.blurMix = random.value(0.35...0.6)
        }
    }

    /// The stages present in a recipe, read back from its layers and effects (used to check
    /// the intensity budget for generated and varied recipes alike).
    static func stages(of art: Artwork) -> [String] {
        var names: [String] = []
        if art.effects.symmetry != .none { names.append("mirror") }
        if art.layers.contains(where: { $0.stretch > 1.001 }) { names.append("stretch") }
        var seen: [SourceImage] = [], layering = Set<String>()
        for layer in art.layers where layer.material == .image {
            let duplicate = layer.image.map { image in seen.contains { $0 === image } } ?? false
            if let image = layer.image { seen.append(image) }
            if duplicate { layering.insert("echo") }
            switch layer.mask {
            case .bright, .dark: layering.insert("luminosity")
            case .linear, .radial: layering.insert("fade")
            case .none:
                if !duplicate, wildBlends.contains(where: { $0.0 == layer.blend }) { layering.insert("blendWild") }
                else if !duplicate, structureBlends.contains(where: { $0.0 == layer.blend }) { layering.insert("blend") }
            }
        }
        names += layering.sorted()
        let e = art.effects
        if e.colour != .none && e.colourMix > 0.001 {
            names.append(e.colour == .hue && abs(e.hue * e.colourMix) > 45 ? "hueLarge" : e.colour.rawValue)
        }
        if e.blur != .none && e.blurAmount > 0.0001 && e.blurMix > 0.001 { names.append(e.blur == .motion ? "motionBlur" : "zoomBlur") }
        if e.grain > 0.001 { names.append("grain") }
        return names
    }
}
