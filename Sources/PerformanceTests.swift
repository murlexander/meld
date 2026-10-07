import AppKit
import ImageIO
import Combine

@MainActor
enum PerformanceTests {
    static func run(output: URL) throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(60)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            check(condition(), "performance workflow settles")
        }
        func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
            guard a.width == b.width, a.height == b.height else { return false }
            let left = NSBitmapImageRep(cgImage: a), right = NSBitmapImageRep(cgImage: b)
            return [(0.13, 0.21), (0.38, 0.73), (0.57, 0.46), (0.82, 0.61)].allSatisfy { u, v in
                let x = Int(u * Double(a.width)), y = Int(v * Double(a.height))
                let c = left.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let d = right.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                return abs(c.redComponent-d.redComponent) < 0.01 && abs(c.greenComponent-d.greenComponent) < 0.01
                    && abs(c.blueComponent-d.blueComponent) < 0.01 && abs(c.alphaComponent-d.alphaComponent) < 0.01
            }
        }
        func previewPixels(_ studio: Studio) -> CGImage {
            // CGImage-backed NSImages may use a private snapshot representation.
            // TIFF preserves that representation's pixels without Retina resampling.
            NSBitmapImageRep(data: studio.preview!.tiffRepresentation!)!.cgImage!
        }

        let folder = output.appendingPathComponent("performance-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sample = Renderer.starterPNG()!
        for i in 0..<12 { try sample.write(to: folder.appendingPathComponent("source-\(i).png")) }
        let loader = MaterialLoader(), renderer = Renderer()
        let url = folder.appendingPathComponent("source-0.png")
        let loaded = loader.load(url, maximum: 1100)!
        let source = loaded.layer.image!
        check(max(source.pixels.width, source.pixels.height) == 1100 && max(source.previewPixels.width, source.previewPixels.height) <= 1000
              && max(source.thumbnail.width, source.thumbnail.height) <= 96,
              "full working copy, preview and sidebar image have independent size bounds")
        var original = Artwork(); original.layers = [loaded.layer]
        let before = renderer.render(original, longEdge: 1000)!
        try Data("source replaced after import".utf8).write(to: url)
        check(samePixels(before, renderer.render(original, longEdge: 1000)!), "working pixels survive a changed or disconnected source file")
        try sample.write(to: url)
        check(loader.load(url, cancelled: { true }) == nil, "cancelled material load performs no decode")
        var visits = 0, cancelledScan = false
        do { _ = try MaterialLoader.scan(folder, cancelled: { visits += 1; return visits > 3 }) }
        catch { cancelledScan = (error as? CocoaError)?.code == .userCancelled }
        check(cancelledScan, "folder traversal honours cancellation between entries")
        weak var releasedSource: SourceImage?
        autoreleasepool {
            let temporary = SourceImage(data: sample)!
            releasedSource = temporary
            var layer = Layer(name: "Shared", material: .image, image: temporary)
            var copy = layer; copy.id = UUID(); copy.scale = 2
            layer.opacity = 0.5
            check(copy.image === layer.image, "layer copies and edits share immutable image storage")
        }
        check(releasedSource == nil, "source storage is released with its last artwork reference")

        // Preserve transparent and wide-gamut input through the new pixel-only path.
        let colourSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colourSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colourSpace, components: [0.8, 0.15, 0.25, 0.5])!)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        let transparent = SourceImage(context.makeImage()!)
        check(transparent.previewImage.extent == transparent.fullImage.extent,
              "preview and full sources use the same coordinates for non-square images")
        let thumb = NSBitmapImageRep(cgImage: transparent.thumbnail)
        check(transparent.pixels.colorSpace?.name == CGColorSpace.displayP3
              && transparent.previewPixels.colorSpace?.name == CGColorSpace.displayP3,
              "preview resizing preserves the input RGB colour space")
        check(abs(thumb.colorAt(x: 10, y: 20)!.alphaComponent - 0.5) < 0.01 && thumb.colorAt(x: 80, y: 20)!.alphaComponent == 0,
              "working previews preserve partial and transparent alpha")

        let studio = Studio(restoreSource: false, starter: false)
        studio.setSourceFolder(folder); wait { !studio.sourceScanning }
        try sample.write(to: folder.appendingPathComponent("added-after-selection.png"))
        studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.sourceCount == 13, "generation sees files added after the folder was selected")
        check(studio.error == nil && studio.trials.count == 36, "progressive material preparation completes the full batch")
        let initialSources = Set(studio.trials.prefix(6).flatMap { $0.art.layers.compactMap(\.sourcePath) })
        let allSources = Set(studio.trials.flatMap { $0.art.layers.compactMap(\.sourcePath) })
        check(initialSources.count <= 3 && allSources.count > initialSources.count,
              "first six previews use the initial pool while later recipes explore more sources")
        var identities: [String: Set<ObjectIdentifier>] = [:]
        for trial in studio.trials {
            for art in [trial.original, trial.art] {
                for layer in art.layers {
                    if let path = layer.sourcePath, let image = layer.image { identities[path, default: []].insert(ObjectIdentifier(image)) }
                }
            }
        }
        check(identities.count <= 12 && identities.values.allSatisfy { $0.count == 1 },
              "36 recipes and their originals retain at most one working image per source")

        let first = studio.trials.first { $0.style == .flow }!
        let second = studio.trials.first { $0.id != first.id }!
        studio.openTrial(first.id); wait { !studio.rendering }
        var updates = 0
        let observer = studio.$preview.dropFirst().sink { _ in updates += 1 }
        for i in 0..<60 {
            studio.change("continuous-colour") { $0.warp.saturation = 0.4 + Double(i) / 60 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        check(updates > 1, "continuous slider changes publish previews before the gesture ends")
        wait { !studio.rendering }
        check(studio.preview?.size.width == 1000 && samePixels(previewPixels(studio), renderer.render(studio.art, longEdge: 1000)!),
              "coalesced slider renders settle to the latest artwork at full Fit resolution")
        observer.cancel()
        studio.setMagnifiedPreview(true); wait { !studio.rendering }
        check(studio.preview?.size.width == 2400, "magnifying still renders at export resolution")
        studio.change("magnified-colour") { $0.warp.saturation = 0.7 }
        wait { !studio.rendering }
        check(studio.preview?.size.width == 2400 && samePixels(previewPixels(studio), renderer.render(studio.art, longEdge: 2400)!),
              "magnified edits settle to full quality after their draft")
        studio.showTrials(); studio.openTrial(second.id); wait { !studio.rendering }
        check(studio.preview?.size.width == 1000, "opening another trial resets magnification to Fit resolution")
        studio.change("rapid-colour") { $0.warp.saturation = 0.1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        studio.openTrial(first.id); wait { !studio.rendering }
        check(samePixels(previewPixels(studio), renderer.render(studio.art, longEdge: 1000)!),
              "an older preview completion cannot replace a newly opened trial")
        studio.change("comparison-race") { $0.warp.saturation = 0 }
        studio.comparing = true; studio.schedule(); wait { !studio.rendering }
        check(samePixels(previewPixels(studio), renderer.render(studio.activeTrial!.original, longEdge: 1000)!),
              "comparison rejects queued adjustment drafts")
        studio.comparing = false; studio.schedule(); wait { !studio.rendering }

        let snapshot = studio.art
        let exportURL = output.appendingPathComponent("performance-export.png")
        studio.export(to: exportURL)
        for i in 0..<24 {
            studio.change("export-adjustment") { $0.warp.saturation = 0.4 + Double(i) / 30 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        wait { !studio.exporting && !studio.rendering }
        let exported = CGImageSourceCreateWithURL(exportURL as CFURL, nil)!
        let exportedPixels = CGImageSourceCreateImageAtIndex(exported, 0, nil)!
        check(studio.error == nil && samePixels(exportedPixels, renderer.render(snapshot, longEdge: 2400)!),
              "concurrent adjustment leaves the exported immutable snapshot intact")
        check(samePixels(previewPixels(studio), renderer.render(studio.art, longEdge: 1000)!),
              "preview remains current while export uses its independent queue")

        // Each new set must reflect the folder as it is now.
        let extra = folder.appendingPathComponent("newly-added.png")
        try sample.write(to: extra)
        studio.showTrials(); studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.sourceCount == 14, "subsequent generation sees newly added source files")
        let exports = output.appendingPathComponent("performance-cancel-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        studio.exportTrials(studio.trials, to: exports)
        wait { studio.trialExportProgress > 0 || !studio.exportingTrials }
        studio.cancelTrialExport(); wait { !studio.exportingTrials }
        let exportFolder = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil).last!
        let saved = try FileManager.default.contentsOfDirectory(at: exportFolder, includingPropertiesForKeys: nil)
        check(studio.trialExportProgress > 0 && studio.trialExportProgress < 36
              && saved.count == studio.trialExportProgress + 1 && saved.contains { $0.lastPathComponent == "Contact sheet.png" },
              "cancelled export keeps completed PNGs and their contact sheet")
        if let rawPath = ProcessInfo.processInfo.environment["MELD_RAW_FIXTURE"] {
            let rawCopy = output.appendingPathComponent("independent-RAW.NEF")
            try Data(contentsOf: URL(fileURLWithPath: rawPath)).write(to: rawCopy)
            let raw = loader.load(rawCopy, maximum: 2400)!.layer.image!
            try FileManager.default.removeItem(at: rawCopy)
            check(max(raw.pixels.width, raw.pixels.height) == 2400 && max(raw.previewPixels.width, raw.previewPixels.height) <= 1000,
                  "RAW retains its developed export copy alongside a smaller reusable preview")
            var rawArt = Artwork(); rawArt.layers = [Layer(name: "RAW", material: .image, image: raw)]
            let firstRender = renderer.render(rawArt, longEdge: 2400)!
            _ = renderer.render(rawArt, longEdge: 480)
            check(samePixels(firstRender, renderer.render(rawArt, longEdge: 2400)!),
                  "RAW preview and export survive source removal without replacing or degrading the working copy")
        }
    }
}
