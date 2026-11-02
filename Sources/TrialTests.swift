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
            let deadline = Date().addingTimeInterval(60)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(condition(), "trial background operation completes")
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
            return (2...3).contains(images.count) && Set(images.compactMap(\.sourcePath)).count == images.count
                && images.allSatisfy { $0.image != nil }
        }, "each trial keeps editable images and never repeats a file within its layers")
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
        func brute(r: Double, k: Double, scale: Double, rotation: Double, x: Double, y: Double) -> Bool {
            let w = 1000 * r, h = 1000.0, extent = CGRect(x: 0, y: 0, width: 777 * k, height: 777)
            let fit = max(w / extent.width, h / extent.height) * scale
            let t = CGAffineTransform(translationX: w * (0.5 + x), y: h * (0.5 - y))
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
            let s = Coverage.minimumCoverScale(canvasAspect: r, imageAspect: k, rotation: rotation, x: x, y: y)
            exact = exact && brute(r: r, k: k, scale: s * 1.000001, rotation: rotation, x: x, y: y)
                && !brute(r: r, k: k, scale: s * 0.999, rotation: rotation, x: x, y: y)
        }
        check(exact, "minimum cover scale matches a brute-force corner test")
        check(abs(Coverage.minimumCoverScale(canvasAspect: 1.4, imageAspect: 1.5, rotation: 0, x: 0, y: 0) - 1) < 1e-9,
              "scale 1 exactly covers the canvas without rotation or offset")

        // Solid, opaque sources of different shapes over a garish background.
        func solid(_ w: Int, _ h: Int) -> PreparedMaterial {
            let c = Renderer.canvas(w: w, h: h)!
            c.setFillColor(Ink(0, 0.6, 0.2).cg); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return PreparedMaterial(Layer(name: "\(w)x\(h)", material: .image, image: SourceImage(c.makeImage()!), sourcePath: "/solid/\(w)x\(h)"))
        }
        let materials = [solid(600, 400), solid(400, 600), solid(500, 500), solid(800, 200), solid(240, 720)]
        func covered(_ art: Artwork) -> Bool {
            art.layers.filter(Coverage.applies).allSatisfy { layer in
                brute(r: art.ratio, k: Coverage.aspect(of: layer, canvas: art.ratio), scale: layer.scale,
                      rotation: layer.rotation, x: layer.x, y: layer.y)
            }
        }
        func photoLed(_ art: Artwork) -> Bool {
            art.layers.filter { $0.material != .image }.allSatisfy { pattern in
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
        var clean = true
        for (i, base) in composed.enumerated() where i % 9 == 0 {
            var art = TrialGenerator.vary(base, materials: materials, seed: UInt64(i), amount: 2)
            art.background = Ink(1, 0, 1)
            art.layers = art.layers.filter { $0.material == .image }.map { var l = $0; l.opacity = 1; l.blend = .normal; return l }
            // Distortions stay on (they must not pull in the background either); colour stays neutral.
            art.warp.saturation = 1; art.warp.contrast = 1
            for bypass in [true, false] {
                let image = renderer.render(art, longEdge: 200, bypass: bypass)!
                let data = image.dataProvider!.data! as Data
                for y in 0..<image.height { for x in 0..<image.width {
                    let o = y * image.bytesPerRow + x * 4
                    if data[o] > 24 || data[o + 2] > 80 { clean = false }
                }}
            }
        }
        check(clean, "rendered generations never reveal the background around a photo")
    }
}
