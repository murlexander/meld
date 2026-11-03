import AppKit
import ImageIO

@MainActor
enum TrialTests {
    static func run(output: URL) throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        func wait(_ condition: () -> Bool) {
            check(SelfTest.settle(condition, step: 0.01), "trial background operation completes")
        }
        func hash(_ image: CGImage) -> UInt64 {
            (image.dataProvider!.data! as Data).reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        let folder = output.appendingPathComponent("trial-sources", isDirectory: true)
        let nested = folder.appendingPathComponent("textures", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Renderer.starterPNG()!.write(to: folder.appendingPathComponent("colour-study.png"))
        for (i, material) in [Material.stripes, .checker, .dots, .rings].enumerated() {
            let layer = Layer(name: material.label, material: material, frequency: Double(4+i*2),
                ink: Ink(0.13+Double(i)*0.18, 0.2, 0.38), paper: Ink(0.94, 0.75-Double(i)*0.12, 0.45+Double(i)*0.14))
            let image = Renderer.pattern(layer, w: 700, h: 500)!
            try Renderer.normalizedPNG(image, maximum: 700)!.write(to: nested.appendingPathComponent("\(material.label).png"))
        }
        try Data("corrupt raw".utf8).write(to: folder.appendingPathComponent("broken.NEF"))
        let urls = try MaterialLoader.scan(folder).urls
        let originals = try urls.map { ($0, try Data(contentsOf: $0)) }
        let studio = Studio(restoreSource: false)
        studio.batchAspect = "Portrait"
        studio.setSourceFolder(folder, scan: false)
        let art = studio.art, selection = studio.selected, revision = studio.revision
        studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.error == nil && studio.trials.count == 36, "a folder creates 36 reviewable previews despite a corrupt RAW")
        check(studio.art == art && studio.selected == selection && studio.revision == revision,
              "making a batch leaves the working canvas, selection and undo history intact")
        check(CompositionStyle.allCases.allSatisfy { style in (7...8).contains(studio.trials.filter { $0.style == style }.count) },
              "36 previews explore every composition style evenly")
        let ordered = studio.trials.sorted { $0.number < $1.number }.map(\.style)
        check(stride(from: 0, to: 36, by: 6).allSatisfy { Set(ordered[$0..<$0 + 6]).count == CompositionStyle.allCases.count },
              "every group of six previews explores all styles")
        check(Set(studio.trials.map { hash($0.thumbnail) }).count == 36, "all 36 generated previews differ")
        check(studio.trials.allSatisfy { $0.art.aspect == "Portrait" && $0.thumbnail.width == 384 && $0.thumbnail.height == 480 },
              "trial thumbnails preserve the chosen canvas shape")
        check(studio.trials.allSatisfy { trial in
            let images = trial.art.layers.filter { $0.material == .image }
            // Only an echo stage repeats a photograph, as one extra layer of the base image.
            let files = Set(images.compactMap(\.sourcePath))
            let repeats = images.count - files.count
            return (2...3).contains(files.count) && repeats <= 1 && images.allSatisfy { $0.image != nil }
                && images.filter { $0.sourcePath == images[0].sourcePath }.count == 1 + repeats
        }, "each trial keeps editable images and repeats a file only as one echo of its base photograph")
        check(studio.trialMessage.contains("unreadable skipped"), "batch reports unreadable materials")
        try TrialGenerator.contactSheet(studio.trials)!.write(to: output.appendingPathComponent("36-previews.png"))
        let renderer = Renderer()
        let prepared = [PreparedMaterial(MaterialLoader().load(folder.appendingPathComponent("colour-study.png"))!.layer)]
        let a = TrialGenerator.compose(prepared, style: .tiles, aspect: "Square", seed: 42)
        let b = TrialGenerator.compose(prepared, style: .tiles, aspect: "Square", seed: 42)
        check(hash(renderer.render(a, longEdge: 320)!) == hash(renderer.render(b, longEdge: 320)!),
              "recipe seeds reproduce the same image")
        var single = a; single.layers[0].tiles = 1
        check(hash(renderer.render(a, longEdge: 320)!) != hash(renderer.render(single, longEdge: 320)!),
              "mirrored tiles change image geometry")
        check(prepared[0].colours.first!.luminance < prepared[0].colours.last!.luminance,
              "source palette retains light and dark colours")
        try fullBleed(check: check)
        try stageChecks(check: check)
        let noise = Layer(name: "Noise", material: .noise, frequency: 13.7)
        let smallNoise = Renderer.pattern(noise, w: 320, h: 320)!, largeNoise = Renderer.pattern(noise, w: 2400, h: 2400)!
        func pixel(_ image: CGImage, _ u: Double, _ v: Double) -> [UInt8] {
            let data = image.dataProvider!.data! as Data
            let offset = Int(v * Double(image.height)) * image.bytesPerRow + Int(u * Double(image.width)) * 4
            return Array(data[offset..<(offset+3)])
        }
        check([(0.1328125, 0.2453125), (0.553, 0.337), (0.827, 0.653)].allSatisfy { u, v in
            zip(pixel(smallNoise, u, v), pixel(largeNoise, u, v)).allSatisfy { abs(Int($0)-Int($1)) <= 1 }
        }, "noise texture keeps the same cells between previews and full-size exports")
        check(studio.stage == .previews && studio.activeTrialID == nil, "generation opens the preview workspace")
        let fresh = Studio(restoreSource: false, starter: false)
        check(fresh.stage == .material && fresh.art.layers.isEmpty && fresh.preview == nil,
              "a session starts at source selection without a sample or manual canvas")
        let chosen = studio.trials.first { $0.style == .flow }!
        studio.comparing = true
        studio.openTrial(chosen.id)
        check(studio.art == chosen.art && studio.stage == .refine && !studio.comparing && studio.current?.material == .image,
              "opening a preview enters refinement with its generated image")
        check(!studio.canUndo, "opening a preview starts its own adjustment history")
        studio.setRefinement("distortion", value: 0)
        check(studio.art.warp.wave == 0 && studio.art.warp.twist == 0 && studio.refinement.distortion == 0,
              "one distortion control scales the generated effects")
        studio.undo()
        check(studio.art == chosen.original && studio.refinement.distortion == 1, "undo restores both the artwork and refinement slider")
        studio.redo()
        check(studio.art.warp.wave == 0 && studio.refinement.distortion == 0, "redo restores the refinement")
        studio.setRefinement("pattern", value: 0.25)
        let beforeStages = studio.art, beforeRefinement = studio.refinement
        studio.setRefinement("colour", value: 0.5)
        check(studio.refinement.colour == 0.5 && abs(studio.art.warp.saturation - chosen.original.warp.saturation * 0.5) < 1e-9,
              "the colour control scales saturation from the generated preview")
        let manual: Symmetry = chosen.original.effects.symmetry == .vertical ? .horizontal : .vertical
        studio.change("stages") { $0.effects.symmetry = manual; $0.effects.grain = 0.1; $0.layers[0].stretch = 1.5; $0.layers[0].mask = .none }
        studio.undo(); studio.undo()
        check(studio.art == beforeStages && studio.refinement == beforeRefinement, "undo restores stage settings and the colour control")
        studio.redo(); studio.redo()
        check(studio.art.effects.symmetry == manual && studio.art.layers[0].stretch == 1.5 && studio.refinement.colour == 0.5,
              "redo restores stage settings and the colour control")
        studio.setRefinement("distortion", value: 0.5)
        check(studio.art.effects.symmetry == manual && studio.art.layers[0].stretch == 1.5 && abs(studio.art.warp.wave - chosen.original.warp.wave * 0.5) < 1e-9,
              "Distortion keeps a mirror and stretch set by hand while scaling the generated warps")
        studio.undo()
        studio.change("colour") { $0.warp.saturation = 0 }
        studio.change("contrast") { $0.warp.contrast = 1.3 }
        let adjusted = studio.art, refined = studio.refinement
        studio.comparing = true; studio.schedule(); wait { !studio.rendering }
        let compared = NSBitmapImageRep(cgImage: studio.preview!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        check([(0.2, 0.3), (0.5, 0.6), (0.8, 0.8)].contains { u, v in
            let colour = compared.colorAt(x: Int(u * Double(compared.pixelsWide)), y: Int(v * Double(compared.pixelsHigh)))!.usingColorSpace(.sRGB)!
            return max(colour.redComponent, colour.greenComponent, colour.blueComponent) - min(colour.redComponent, colour.greenComponent, colour.blueComponent) > 0.05
        } && studio.art == adjusted, "comparison shows the generated colours without changing adjustments")
        studio.showTrials()
        check(studio.stage == .previews && studio.activeTrialID == nil && studio.trials.first { $0.id == chosen.id }!.art == adjusted,
              "returning to previews stores adjustments with the correct image")
        wait { hash(studio.trials.first { $0.id == chosen.id }!.thumbnail) != hash(chosen.thumbnail) }
        let other = studio.trials.first { $0.id != chosen.id }!
        studio.openTrial(other.id)
        check(studio.art == other.original && !studio.canUndo, "another preview has independent artwork and undo history")
        studio.openTrial(chosen.id)
        check(studio.art == adjusted && studio.refinement == refined, "reopening a preview restores its adjustments")
        studio.resetActiveTrial(); check(studio.art == chosen.original && studio.refinement == Refinement(), "reset returns to the generated preview")
        studio.undo(); check(studio.art == adjusted && studio.refinement == refined, "reset is undoable")
        studio.chooseMaterial()
        check(studio.stage == .material && studio.trials.count == 36, "choosing material preserves previews until new generation succeeds")
        studio.showTrials()
        studio.toggleFavourite(chosen.id); studio.toggleFavourite(other.id)
        studio.toggleFavourite(UUID())
        check(studio.favouriteTrials.count == 2, "favourites track only valid trials")
        var favourites = studio.trials.filter { studio.favouriteTrials.contains($0.id) }
        let editedIndex = favourites.firstIndex { $0.id == chosen.id }!
        // Export must reflect edits even if the gallery thumbnail has not refreshed yet.
        favourites[editedIndex].thumbnail = chosen.thumbnail
        let exports = output.appendingPathComponent("trial-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let oldDirectories = Set(try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil))
        studio.exportTrials(favourites, to: exports); wait { !studio.exportingTrials }
        let newDirectories = Set(try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)).subtracting(oldDirectories)
        check(studio.error == nil && newDirectories.count == 1, "favourites export into a new isolated folder")
        let exported = try FileManager.default.contentsOfDirectory(at: newDirectories.first!, includingPropertiesForKeys: nil)
        check(exported.count == 3 && exported.contains { $0.lastPathComponent == "Contact sheet.png" },
              "export contains two favourite PNGs and their contact sheet")
        for url in exported where url.lastPathComponent != "Contact sheet.png" {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            check(image.width == 1920 && image.height == 2400, "exported trial has full resolution and correct aspect")
            let trial = favourites.first { "\($0.title).png" == url.lastPathComponent }!
            let expected = NSBitmapImageRep(cgImage: renderer.render(trial.art, longEdge: 2400)!)
            let actual = NSBitmapImageRep(cgImage: image)
            check([(400, 500), (1000, 1600), (1500, 2100)].allSatisfy { x, y in
                let a = actual.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let b = expected.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                return abs(a.redComponent-b.redComponent) < 0.01 && abs(a.greenComponent-b.greenComponent) < 0.01 && abs(a.blueComponent-b.blueComponent) < 0.01
            }, "exported PNG matches the stored adjustments")
        }
        let contact = NSBitmapImageRep(data: try Data(contentsOf: newDirectories.first!.appendingPathComponent("Contact sheet.png")))!
        let contactColour = contact.colorAt(x: editedIndex * 300 + 150, y: 165)!.usingColorSpace(.sRGB)!
        check(max(contactColour.redComponent, contactColour.greenComponent, contactColour.blueComponent) - min(contactColour.redComponent, contactColour.greenComponent, contactColour.blueComponent) < 0.02,
              "exported contact sheet uses adjusted images even with stale thumbnails")
        let savedIDs = studio.trials.map(\.id), savedFavourites = studio.favouriteTrials
        studio.makeTrials()
        studio.openTrial(savedIDs[0])
        check(studio.stage == .previews && studio.activeTrialID == nil,
              "generation keeps review navigation safe while replacing a set")
        studio.cancelTrials()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!studio.makingTrials && studio.trials.map(\.id) == savedIDs && studio.favouriteTrials == savedFavourites,
              "cancelling before the first result preserves existing trials and favourites")
        studio.makeTrials(count: 48); wait { studio.trialProgress > 0 || !studio.makingTrials }
        studio.cancelTrials()
        let partial = studio.trials.map(\.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!partial.isEmpty && partial.count < 48 && studio.trials.map(\.id) == partial && !studio.makingTrials,
              "stopping midway keeps reviewable results and ignores late callbacks")
        studio.openTrial(partial[0])
        check(studio.stage == .refine && studio.activeTrialID == partial[0],
              "stopped previews can be refined immediately")
        studio.showTrials()
        let empty = output.appendingPathComponent("trial-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        studio.setSourceFolder(empty, scan: false); studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.error != nil && studio.trials.map(\.id) == partial,
              "an empty folder preserves the previous trials")
        studio.error = nil
        studio.setSourceFolder(empty.appendingPathComponent("missing"), scan: false)
        studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.error != nil && studio.trials.map(\.id) == partial, "an unavailable source preserves previous trials")
        studio.error = nil; studio.setSourceFolder(folder, scan: false)
        studio.makeTrials(); studio.clearSourceFolder()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(!studio.makingTrials && studio.sourceFolder == nil && studio.trials.map(\.id) == partial,
              "disconnecting a source cancels generation without discarding trials")
        for (url, bytes) in originals { check(try Data(contentsOf: url) == bytes, "batch leaves original \(url.lastPathComponent) unchanged") }
        if let rawPath = ProcessInfo.processInfo.environment["MELD_RAW_FIXTURE"] {
            let rawFolder = output.appendingPathComponent("trial-raw", isDirectory: true)
            try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(fileURLWithPath: rawPath))
            let rawURL = rawFolder.appendingPathComponent("material.NEF")
            try data.write(to: rawURL)
            let rawStudio = Studio(restoreSource: false)
            rawStudio.setSourceFolder(rawFolder, scan: false)
            rawStudio.makeTrials(); wait { !rawStudio.makingTrials }
            check(rawStudio.error == nil && rawStudio.trials.count == 36, "a single real RAW produces 36 previews")
            check(Set(rawStudio.trials.map { hash($0.thumbnail) }).count == 36, "RAW-only trials remain varied")
            check(try Data(contentsOf: rawURL) == data, "RAW batch preserves the original bytes")
            try TrialGenerator.contactSheet(rawStudio.trials)!.write(to: output.appendingPathComponent("36-raw-previews.png"))
        }
    }

    /// Generated and varied layers always cover the canvas: no photo edges or background show.
    static func fullBleed(check: (Bool, String) -> Void) throws {
        // Independent of `Coverage`: map the canvas corners through the inverse of the
        // Renderer's own layer transform and test them against the source extent.
        func brute(r: Double, k: Double, scale: Double, rotation: Double, x: Double, y: Double, stretch: Double = 1, along: Double = 0) -> Bool {
            let w = 1000 * r, h = 1000.0, extent = CGRect(x: 0, y: 0, width: 777 * k, height: 777)
            let fit = max(w / extent.width, h / extent.height) * scale
            let t = CGAffineTransform(translationX: w * (0.5 + x), y: h * (0.5 - y))
                .rotated(by: along * .pi / 180).scaledBy(x: stretch, y: 1).rotated(by: -along * .pi / 180)
                .rotated(by: rotation * .pi / 180).scaledBy(x: fit, y: fit)
                .translatedBy(x: -extent.midX, y: -extent.midY).inverted()
            return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
                .allSatisfy { extent.insetBy(dx: -1e-6, dy: -1e-6).contains($0.applying(t)) }
        }
        var random = RecipeRandom(seed: 2026)
        var exact = true
        for _ in 0..<4000 {
            let r = random.value(0.4...2.5), k = random.value(0.25...4), rotation = random.value(-180...180)
            let x = random.value(-0.6...0.6), y = random.value(-0.6...0.6)
            let f = random.value(0...1) < 0.5 ? 1 : random.value(1...3.2), along = random.value(-180...180)
            let s = Coverage.minimumCoverScale(canvasAspect: r, imageAspect: k, rotation: rotation, x: x, y: y, stretch: f, stretchAngle: along)
            exact = exact && brute(r: r, k: k, scale: s * 1.000001, rotation: rotation, x: x, y: y, stretch: f, along: along)
                && !brute(r: r, k: k, scale: s * 0.999, rotation: rotation, x: x, y: y, stretch: f, along: along)
        }
        check(exact, "minimum cover scale matches a brute-force corner test, with and without one-axis stretch")
        check(abs(Coverage.minimumCoverScale(canvasAspect: 1.4, imageAspect: 1.5, rotation: 0, x: 0, y: 0) - 1) < 1e-9,
              "scale 1 exactly covers the canvas without rotation or offset")

        // Solid, opaque sources of different shapes over a garish background.
        // Opaque sources in distinct colours, so masks and fades visibly change the result.
        func solid(_ w: Int, _ h: Int, _ ink: Ink = Ink(0, 0.6, 0.2)) -> PreparedMaterial {
            let c = Renderer.canvas(w: w, h: h)!
            c.setFillColor(ink.cg); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return PreparedMaterial(Layer(name: "\(w)x\(h)", material: .image, image: SourceImage(c.makeImage()!), sourcePath: "/solid/\(w)x\(h)"))
        }
        let materials = [solid(600, 400), solid(400, 600, Ink(0.85, 0.75, 0.1)), solid(500, 500, Ink(0.1, 0.2, 0.7)),
                         solid(800, 200, Ink(0.9, 0.9, 0.9)), solid(240, 720, Ink(0.05, 0.05, 0.05))]
        func covered(_ art: Artwork) -> Bool {
            art.layers.filter(Coverage.applies).allSatisfy { layer in
                brute(r: art.ratio, k: Coverage.aspect(of: layer, canvas: art.ratio), scale: layer.scale,
                      rotation: layer.rotation, x: layer.x, y: layer.y, stretch: layer.stretch, along: layer.stretchAngle)
            }
        }
        func photoLed(_ art: Artwork) -> Bool {
            // The base photograph stays whole and opaque; stages only layer others over it.
            guard let base = art.layers.first, base.material == .image, base.mask == .none,
                  base.opacity == 1, base.blend == .normal else { return false }
            return art.layers.filter { $0.material != .image }.allSatisfy { pattern in
                pattern.opacity <= TrialGenerator.patternOpacityCap + 1e-9 && pattern.blend != .normal
                    && TrialGenerator.patternBlends.contains(pattern.blend) && pattern.material != .stripes
            }
        }
        var composed: [Artwork] = [], allCovered = true, subtle = true
        for aspect in ["Square", "Portrait", "Landscape"] {
            for style in CompositionStyle.allCases {
                for seed in 1...60 {
                    let art = TrialGenerator.compose(materials, style: style, aspect: aspect, seed: UInt64(seed))
                    composed.append(art)
                    allCovered = allCovered && covered(art)
                    subtle = subtle && photoLed(art)
                    var relative = art
                    for (i, amount) in [0.5, 1, 1.5, 2].enumerated() {
                        let varied = TrialGenerator.vary(art, materials: materials, seed: UInt64(seed * 10 + i), amount: amount)
                        allCovered = allCovered && covered(varied)
                        subtle = subtle && photoLed(varied)
                        // Variations of variations must not drift past the cap either.
                        relative = TrialGenerator.vary(relative, materials: materials, seed: UInt64(seed * 10 + i + 5), amount: 2)
                        subtle = subtle && photoLed(relative)
                    }
                }
            }
        }
        check(allCovered, "every generated and varied image and pattern layer covers the canvas in all styles and shapes")
        check(subtle, "generated and varied patterns stay a faint, non-normal texture without bold stripes")
        let placed = composed.flatMap { art in art.layers.filter { $0.material == .image && $0.tiles <= 1 }.map { (art.ratio, $0) } }
        let turned = placed.filter { abs($0.1.rotation) > 45 }.count
        let zooms = placed.map { ratio, layer in
            layer.scale / Coverage.minimumCoverScale(canvasAspect: ratio, imageAspect: Coverage.aspect(of: layer, canvas: ratio),
                                                     rotation: layer.rotation, x: 0, y: 0)
        }
        check(Double(turned) > Double(placed.count) * 0.35 && zooms.filter { $0 >= 2 }.count > placed.count / 8
              && zooms.filter { $0 < 1.1 }.count > placed.count / 8,
              "placements mix large rotations, plain crops and strong detail zooms")
        check(zip(placed, zooms).allSatisfy { $0.1.scale <= max(4, $0.1.scale / $1 * Coverage.margin) + 1e-9 },
              "generated zoom stays within what a 2400-pixel source supports unless coverage needs more")
        check(!CompositionStyle.allCases.contains { ["Collage", "Weave"].contains($0.rawValue) },
              "no style places shrunken photos over a ground or covers them with a bold pattern")
        check(CompositionStyle.allCases.allSatisfy { style in TrialGenerator.styles(count: 600, seed: 9).filter { $0 == style }.count == 120 },
              "long style sequences stay balanced")

        let renderer = Renderer()
        // The background shows wherever two renders on different backgrounds differ; this needs
        // no colour thresholds, so grain, masks and colour treatments can all stay on.
        func pixels(_ art: Artwork, _ background: Ink, edge: Int, bypass: Bool) -> (Data, CGImage) {
            var art = art; art.background = background
            let image = renderer.render(art, longEdge: edge, bypass: bypass)!
            return (image.dataProvider!.data! as Data, image)
        }
        func reveals(_ art: Artwork, bypass: Bool = false, edge: Int = 160) -> Bool {
            let (magenta, image) = pixels(art, Ink(1, 0, 1), edge: edge, bypass: bypass)
            let (cyan, _) = pixels(art, Ink(0, 1, 1), edge: edge, bypass: bypass)
            return magenta.withUnsafeBytes { (m: UnsafeRawBufferPointer) -> Bool in
                cyan.withUnsafeBytes { (c: UnsafeRawBufferPointer) -> Bool in
                    for y in 0..<image.height { for x in 0..<image.width {
                        let o = y * image.bytesPerRow + x * 4
                        if m[o + 3] < 255 || abs(Int(m[o]) - Int(c[o])) > 1 || abs(Int(m[o + 1]) - Int(c[o + 1])) > 1
                            || abs(Int(m[o + 2]) - Int(c[o + 2])) > 1 { return true }
                    }}
                    return false
                }
            }
        }
        var clean = true
        for (i, base) in composed.enumerated() where i % 18 == 0 {
            let art = TrialGenerator.vary(base, materials: materials, seed: UInt64(i), amount: 2)
            clean = clean && !reveals(art, bypass: true) && !reveals(art)
        }
        check(clean, "rendered generations and their variations never reveal the background, with or without distortions")
        // Every geometry, layering and surface stage, in every style and shape, off-centre.
        let forced: [StagePlan] = [
            StagePlan(geometry: .mirror, layering: .luminosity, colour: .gradientMap, surface: .motionBlur),
            StagePlan(geometry: .stretch, layering: .fade, colour: .posterize, surface: .zoomBlur),
            StagePlan(geometry: .mirror, layering: .echo, colour: .paletteSwap, surface: .grain),
            StagePlan(geometry: .stretch, layering: .blend, surface: .motionBlur)]
        var stagesClean = true, seen = Set<String>()
        for (k, aspect) in ["Square", "Portrait", "Landscape"].enumerated() {
            for style in CompositionStyle.allCases {
                for (j, plan) in forced.enumerated() {
                    let seed = 1 + (k + j) % 3
                    var art = TrialGenerator.compose(materials, style: style, aspect: aspect, seed: UInt64(seed * 31 + j), plan: plan)
                    if plan.geometry == .mirror { art.effects.symmetry = Symmetry.allCases[1 + seed % 3]; art.effects.splitX = seed == 1 ? 0.38 : 0.62; art.effects.splitY = seed == 2 ? 0.38 : 0.62 }
                    if plan.surface == .motionBlur || plan.surface == .zoomBlur { art.effects.blurAmount = 0.08; art.effects.blurMix = 1 }
                    seen.formUnion(TrialGenerator.stages(of: art))
                    for i in art.layers.indices where art.layers[i].mask == .radial { art.layers[i].maskX = 0.05; art.layers[i].maskY = 0.95 }
                    stagesClean = stagesClean && covered(art) && !reveals(art)
                }
            }
        }
        check(stagesClean && seen.isSuperset(of: ["mirror", "stretch", "luminosity", "fade", "echo", "motionBlur", "zoomBlur", "grain"]),
              "mirror, stretch, masks, fades, echoes, blurs, grain and colour never reveal the background or leave transparency")
        // Reduced-size blurs at export size, where the reduced canvas is not a whole number of pixels.
        var exportBlurs = true
        for aspect in ["Landscape", "Portrait"] {
            for surface in [StagePlan.Surface.motionBlur, .zoomBlur] {
                var art = TrialGenerator.compose(materials, style: .flow, aspect: aspect, seed: 4, plan: StagePlan(layering: .fade, surface: surface))
                art.effects.blurAmount = 0.1; art.effects.blurMix = 1
                exportBlurs = exportBlurs && !reveals(art, edge: 2400)
            }
        }
        check(exportBlurs, "motion and zoom blur leave no edge or transparent row at 2400 pixels in landscape and portrait")

        // Masks show the upper photograph exactly where they should: two distinct colours.
        func split(_ left: Ink, _ right: Ink) -> Layer {
            let c = Renderer.canvas(w: 400, h: 400)!
            c.setFillColor(left.cg); c.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
            c.setFillColor(right.cg); c.fill(CGRect(x: 200, y: 0, width: 200, height: 400))
            return Layer(name: "split", material: .image, image: SourceImage(c.makeImage()!))
        }
        func colour(_ art: Artwork, _ x: Int, _ y: Int) -> (Int, Int, Int) {
            let image = renderer.render(art, longEdge: 200)!
            let data = image.dataProvider!.data! as Data
            let o = y * image.bytesPerRow + x * 4
            return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
        }
        func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 40 && c.2 < 40 }
        let red = split(Ink(1, 0, 0), Ink(1, 0, 0))
        var maskArt = Artwork(); maskArt.layers = [split(Ink(0, 0, 0), Ink(1, 1, 1)), red]
        func masked(_ kind: MaskKind, _ base: Layer) -> Artwork {
            var art = maskArt; art.layers[0] = base
            art.layers[1].mask = kind; art.layers[1].maskSoftness = 0.04
            art.layers[1].maskPosition = kind == .radial ? 0.2 : kind == .linear ? 0 : 0.5
            art.layers[1].maskAngle = 0; art.layers[1].maskX = 0.5; art.layers[1].maskY = 0.5
            return art
        }
        let blackWhite = maskArt.layers[0], grey = split(Ink(0.4, 0.4, 0.4), Ink(0.4, 0.4, 0.4))
        let bright = masked(.bright, blackWhite), dark = masked(.dark, blackWhite)
        let linear = masked(.linear, grey), radial = masked(.radial, grey)
        check(!isRed(colour(bright, 40, 100)) && isRed(colour(bright, 160, 100))
              && isRed(colour(dark, 40, 100)) && !isRed(colour(dark, 160, 100))
              && !isRed(colour(linear, 30, 100)) && isRed(colour(linear, 170, 100))
              && isRed(colour(radial, 100, 100)) && !isRed(colour(radial, 10, 10)),
              "bright, dark, linear and radial masks show the upper photograph only in their own region")
    }

    /// Stage plans: probabilities, the intensity budget, set diversity, determinism and sliders.
    static func stageChecks(check: (Bool, String) -> Void) throws {
        func source(_ w: Int, _ h: Int, _ a: Ink, _ b: Ink, _ name: String) -> PreparedMaterial {
            let c = Renderer.canvas(w: w, h: h)!
            c.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a.cg, b.cg] as CFArray, locations: [0, 1])!,
                                 start: .zero, end: CGPoint(x: w, y: h), options: [])
            c.setFillColor(b.cg); c.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 3, height: h / 3))
            return PreparedMaterial(Layer(name: name, material: .image, image: SourceImage(c.makeImage()!), sourcePath: "/stages/\(name)"))
        }
        let materials = [source(600, 400, Ink(0.1, 0.15, 0.3), Ink(0.95, 0.8, 0.5), "a"), source(400, 600, Ink(0.3, 0.05, 0.1), Ink(0.7, 0.9, 0.8), "b"),
                         source(500, 500, Ink(0.05, 0.2, 0.1), Ink(0.9, 0.6, 0.3), "c"), source(700, 300, Ink(0.2, 0.2, 0.2), Ink(0.9, 0.9, 0.85), "d")]
        // Probabilities, the quiet share and the budget, over many sets.
        var counts: [String: Int] = [:], quiet = 0, total = 0, budget = true, diverse = true, quietGroups = true
        for seed in 1...150 {
            let plans = TrialGenerator.plans(count: 36, seed: UInt64(seed))
            diverse = diverse && Set(plans).count == 36
            for start in stride(from: 0, to: 36, by: 6) {
                let group = Array(plans[start..<start + 6])
                quietGroups = quietGroups && group.contains { $0.count == 1 }
                for i in 0..<6 { for j in (i + 1)..<6 where group[i].overlap(group[j]) > 1 { diverse = false } }
            }
            for plan in plans {
                total += 1; if plan.count == 1 { quiet += 1 }
                for name in plan.names { counts[name, default: 0] += 1 }
                budget = budget && plan.count >= 1 && plan.strongCount <= StagePlan.strongLimit && StagePlan.weight(plan.names) <= StagePlan.weightLimit
            }
        }
        let odds = StagePlan.geometryOdds.map { ($0.0.rawValue, $0.1) } + StagePlan.layeringOdds.map { ($0.0.rawValue, $0.1) }
            + StagePlan.colourOdds.map { ($0.0.rawValue, $0.1) } + StagePlan.surfaceOdds.map { ($0.0.rawValue, $0.1) }
        let frequencies = odds.map { name, p in (name, p, Double(counts[name] ?? 0) / Double(total)) }
        print("Stage frequencies: " + frequencies.map { String(format: "%@ %.2f (odds %.2f)", $0.0, $0.2, $0.1) }.joined(separator: ", ")
              + String(format: "; quiet %.2f", Double(quiet) / Double(total)))
        check(frequencies.allSatisfy { _, p, f in f >= p * 0.45 && f <= p * 1.5 }, "stage frequencies follow their probabilities over many seeds")
        check((0.17...0.27).contains(Double(quiet) / Double(total)) && quietGroups,
              "about one preview in five is quiet (base style plus one stage), at least one per group of six")
        check(budget, "every plan keeps within two strong stages and the intensity budget")
        check(diverse, "no stage combination repeats within a set, and previews in a group of six share at most one stage choice")
        check(TrialGenerator.plans(count: 36, seed: 77) == TrialGenerator.plans(count: 36, seed: 77)
              && TrialGenerator.plans(count: 36, seed: 77) != TrialGenerator.plans(count: 36, seed: 78), "stage plans are deterministic per seed")

        // Composed and varied recipes: detected stages match the plan and keep the budget.
        func within(_ names: [String]) -> Bool {
            names.filter(StagePlan.strong.contains).count <= StagePlan.strongLimit && StagePlan.weight(names) <= StagePlan.weightLimit
        }
        var matches = true, kept = true, revived = false, occurred = Set<String>()
        for seed in 1...8 {
            let plans = TrialGenerator.plans(count: 36, seed: UInt64(seed)), styles = TrialGenerator.styles(count: 36, seed: UInt64(seed))
            for i in 0..<36 {
                let art = TrialGenerator.compose(materials, style: styles[i], aspect: ["Square", "Portrait", "Landscape"][i % 3], seed: UInt64(seed * 100 + i), plan: plans[i])
                let names = TrialGenerator.stages(of: art)
                occurred.formUnion(names)
                matches = matches && Set(names.map { $0 == "blendWild" ? "blend" : $0 }) == Set(plans[i].names)
                kept = kept && within(names)
                // Long chains of bold relatives, also from previews whose colour and distortion
                // controls were turned to 0: nothing revives and the budget always holds.
                var neutral = art
                Refinement.apply("colour", value: 0, previous: 1, original: art, to: &neutral)
                Refinement.apply("distortion", value: 0, previous: 1, original: art, to: &neutral)
                for start in [art, neutral] {
                    var relative = start
                    for step in 0..<10 {
                        relative = TrialGenerator.vary(relative, materials: materials, seed: UInt64(seed * 10000 + i * 100 + step), amount: step % 2 == 0 ? 2 : 1.4)
                        let names = TrialGenerator.stages(of: relative)
                        kept = kept && within(names) && !names.contains("hueLarge")
                        if start == neutral {
                            let e = relative.effects
                            revived = revived || (e.colour != .none && e.colour == start.effects.colour && e.colourMix > 0)
                                || (e.blur != .none && e.blur == start.effects.blur && e.blurAmount > 0)
                                || zip(relative.layers, start.layers).contains { $0.stretch > 1.0001 && $1.stretch <= 1.0001 }
                        }
                    }
                }
            }
        }
        check(matches, "generated recipes contain exactly their planned stages")
        check(kept, "generated recipes and long chains of bold variations stay within the intensity budget, with small hue shifts")
        check(!revived, "variations never revive a colour treatment, blur or stretch that a control turned off")
        let every: Set<String> = ["mirror", "stretch", "luminosity", "fade", "echo", "blend", "gradientMap", "paletteSwap", "posterize", "hue", "motionBlur", "zoomBlur", "grain"]
        check(occurred.isSuperset(of: every), "every stage occurs across a few sets")
        var swapped = 0, nudged = 0
        let rich = TrialGenerator.compose(materials, style: .flow, aspect: "Square", seed: 5,
                                          plan: StagePlan(geometry: .mirror, layering: .fade, colour: .paletteSwap, surface: .motionBlur))
        for seed in 1...200 {
            let close = TrialGenerator.vary(rich, materials: materials, seed: UInt64(seed), amount: 0.6)
            if TrialGenerator.stages(of: close) == TrialGenerator.stages(of: rich) && close.effects != rich.effects { nudged += 1 }
            let bold = TrialGenerator.vary(rich, materials: materials, seed: UInt64(seed), amount: 1.8)
            if TrialGenerator.stages(of: bold) != TrialGenerator.stages(of: rich) { swapped += 1 }
        }
        check(nudged == 200 && swapped > 20 && swapped < 150,
              "close variations nudge stage settings; bolder ones sometimes swap one stage")

        // Determinism of the rendered stages.
        let renderer = Renderer()
        func hash(_ art: Artwork) -> UInt64 {
            (renderer.render(art, longEdge: 240)!.dataProvider!.data! as Data).reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        let again = TrialGenerator.compose(materials, style: .flow, aspect: "Square", seed: 5,
                                           plan: StagePlan(geometry: .mirror, layering: .fade, colour: .paletteSwap, surface: .motionBlur))
        var layersMatch = again; layersMatch.layers = zip(again.layers, rich.layers).map { var l = $0; l.id = $1.id; return l }
        check(layersMatch == rich && hash(again) == hash(rich), "the same seed and plan reproduce the same staged image")

        // Sliders at 0 turn their stages off; 100% restores the recipe.
        let stretched = TrialGenerator.compose(materials, style: .detail, aspect: "Portrait", seed: 9,
                                               plan: StagePlan(geometry: .stretch, layering: .fade, colour: .posterize, surface: .grain))
        var sliders = true
        for original in [rich, stretched] {
            var art = original
            Refinement.apply("distortion", value: 0, previous: 1, original: original, to: &art)
            let names = TrialGenerator.stages(of: art)
            sliders = sliders && !names.contains { ["mirror", "stretch", "motionBlur", "zoomBlur"].contains($0) }
                && art.warp.wave == 0 && art.warp.twist == 0 && art.layers.allSatisfy { Coverage.covers($0, canvas: art.ratio) }
            Refinement.apply("distortion", value: 1, previous: 0, original: original, to: &art)
            sliders = sliders && art == original
            Refinement.apply("colour", value: 0, previous: 1, original: original, to: &art)
            sliders = sliders && art.warp.saturation == 0 && art.effects.colourMix == 0
                && !TrialGenerator.stages(of: art).contains { ["gradientMap", "paletteSwap", "posterize", "hue"].contains($0) }
            // At the same saturation, a zero mix renders exactly like no treatment, while the
            // generated mix visibly changes the image.
            var zeroMix = original; zeroMix.effects.colourMix = 0
            var untreated = original; untreated.effects.colour = .none
            sliders = sliders && hash(zeroMix) == hash(untreated) && hash(original) != hash(untreated)
            Refinement.apply("colour", value: 1, previous: 0, original: original, to: &art)
            Refinement.apply("pattern", value: 0, previous: 1, original: original, to: &art)
            sliders = sliders && art.effects.grain == 0 && art.layers.filter { $0.material != .image }.allSatisfy { $0.opacity == 0 }
                && art.warp.contrast == original.warp.contrast
            Refinement.apply("pattern", value: 1.5, previous: 0, original: original, to: &art)
            sliders = sliders && art.layers.filter { $0.material != .image }.allSatisfy { $0.opacity <= TrialGenerator.patternOpacityCap + 1e-9 }
            Refinement.apply("pattern", value: 1, previous: 1.5, original: original, to: &art)
            sliders = sliders && art == original
        }
        check(sliders, "distortion, colour and pattern at 0 turn their stages off, keep coverage and the texture cap, and 100% restores the recipe")
        // Inspector edits survive the simple controls: mirror four ways, a motion blur and a
        // gradient map set by hand stay as set while Distortion and Colour move.
        var edited = rich
        edited.effects.symmetry = .both; edited.effects.blur = .motion; edited.effects.blurAmount = 0.05; edited.effects.blurMix = 0.6
        edited.effects.colour = .gradientMap; edited.effects.colourMix = 0.8; edited.effects.colours = [Ink(0.1, 0.1, 0.2), Ink(0.9, 0.8, 0.6)]
        var nudgedArt = edited
        Refinement.apply("distortion", value: 0.6, previous: 1, original: rich, to: &nudgedArt)
        Refinement.apply("distortion", value: 0, previous: 0.6, original: rich, to: &nudgedArt)
        Refinement.apply("colour", value: 0.5, previous: 1, original: rich, to: &nudgedArt)
        check(nudgedArt.effects == edited.effects && nudgedArt.warp.wave == 0 && abs(nudgedArt.warp.saturation - rich.warp.saturation * 0.5) < 1e-9,
              "the simple controls keep stage settings edited under More controls and still scale the rest")
        // The heaviest combinations over the strongest warps still render at export size
        // within the 128 MB render-task memory target.
        var heavy = true
        for (style, plan) in [(CompositionStyle.vortex, StagePlan(geometry: .mirror, layering: .fade, colour: .gradientMap, surface: .zoomBlur)),
                              (.flow, StagePlan(geometry: .stretch, layering: .luminosity, colour: .posterize, surface: .motionBlur)),
                              (.blocks, StagePlan(geometry: .mirror, layering: .echo, colour: .paletteSwap, surface: .grain))] {
            var art = TrialGenerator.compose(materials, style: style, aspect: "Landscape", seed: 3, plan: plan)
            if art.effects.symmetry != .none { art.effects.symmetry = .both }
            heavy = heavy && autoreleasepool { renderer.render(art, longEdge: 2400) } != nil
        }
        check(heavy, "mirrored, blurred, masked and colour-treated recipes render at 2400 pixels")
        // Whole sets render: every preview of a set returns an image, in every shape.
        var complete = true
        for (k, aspect) in ["Square", "Portrait", "Landscape"].enumerated() {
            let seed = UInt64(40 + k)
            let plans = TrialGenerator.plans(count: 36, seed: seed), styles = TrialGenerator.styles(count: 36, seed: seed)
            for i in 0..<36 {
                let art = TrialGenerator.compose(materials, style: styles[i], aspect: aspect, seed: seed &+ UInt64(i + 1), plan: plans[i])
                complete = complete && autoreleasepool { renderer.render(art, longEdge: 480) } != nil
            }
        }
        check(complete, "full sets of 36 staged previews all render in square, portrait and landscape")
    }
}
