import AppKit
import ImageIO

enum SelfTest {
    static func run() {
        let output = URL(fileURLWithPath: CommandLine.arguments.last ?? "/private/tmp/meld-checks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let renderer = Renderer()
            guard let sample = Renderer.starterPNG() else { fatalError("Starter generation failed") }
            var art = Artwork(); art.layers = [Layer(name: "Colour study", material: .image, image: sample)]
            func check(_ value: Bool, _ message: String) {
                if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
                print("PASS: \(message)")
            }
            func waitFor(_ condition: () -> Bool) {
                let deadline = Date().addingTimeInterval(60)
                while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                check(condition(), "background material operation completes")
            }
            func hash(_ cg: CGImage) -> UInt64 {
                let bytes = cg.dataProvider!.data! as Data
                return bytes.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            }
            let retinaImage = CanvasZoomGeometry.imageSize(ratio: 1, displayScale: 2)
            check(retinaImage == CGSize(width: 1200, height: 1200), "100% zoom maps export pixels to Retina display pixels")
            check(CanvasZoomGeometry.fit(image: retinaImage, viewport: CGSize(width: 624, height: 824)) == 0.5,
                  "Fit accounts for viewport and canvas padding")
            check(CanvasZoomGeometry.imageSize(ratio: 0.8, displayScale: 1) == CGSize(width: 1920, height: 2400),
                  "portrait zoom preserves export aspect ratio")
            for scale: CGFloat in [0.05, 0.3, 1, 2, 4] {
                check(abs(CanvasZoomGeometry.scale(CanvasZoomGeometry.fraction(scale)) - scale) < 0.00001,
                      "zoom slider round trip at \(scale)")
            }
            let resetStudio = Studio(restoreSource: false)
            resetStudio.change("twist") { $0.warp.twist = 2 }
            let nativeSlider = ResetSlider()
            nativeSlider.onChange = { value in resetStudio.change("twist") { $0.warp.twist = value } }
            nativeSlider.onReset = { resetStudio.change("twist") { $0.warp.twist = Warp().twist } }
            let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            nativeSlider.mouseDown(with: doubleClick)
            check(resetStudio.art.warp.twist == 0, "native slider double-click resets the adjustment")
            nativeSlider.minValue = -5; nativeSlider.maxValue = 5
            nativeSlider.doubleValue = 1.5; nativeSlider.changed()
            check(resetStudio.art.warp.twist == 1.5, "native slider keeps normal value tracking")
            let beforeZoom = resetStudio.art, zoomRevision = resetStudio.revision
            resetStudio.setMagnifiedPreview(true)
            waitFor { !resetStudio.rendering }
            let magnifiedRep = resetStudio.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            check(magnifiedRep?.width == 2400, "magnified preview renders at full export resolution")
            resetStudio.setMagnifiedPreview(false)
            waitFor { !resetStudio.rendering }
            check(resetStudio.art == beforeZoom && resetStudio.revision == zoomRevision,
                  "zoom resolution changes never edit the artwork or undo history")
            let baseline = renderer.render(art, longEdge: 320)!
            check(baseline.width == 320 && baseline.height == 320, "square canvas dimensions")
            let baseHash = hash(baseline)
            for material in Material.allCases where material != .image {
                var copy = art
                copy.layers.append(Layer(name: material.label, material: material, opacity: 0.5, blend: .multiply))
                let image = renderer.render(copy, longEdge: 320)
                check(image != nil && hash(image!) != baseHash, "\(material.label) changes the artwork")
            }
            for blend in Blend.allCases {
                var copy = art
                copy.layers.append(Layer(name: "Pattern", material: .checker, opacity: 0.5, blend: blend))
                let result = renderer.render(copy, longEdge: 320)
                check(result != nil && hash(result!) != baseHash, "\(blend.label) blending")
            }
            for (name, path, value) in [("wave", \Warp.wave, 0.5), ("twist", \Warp.twist, 2.0), ("bulge", \Warp.bulge, 0.5), ("pixelate", \Warp.pixel, 0.5), ("saturation", \Warp.saturation, 0.0)] {
                var copy = art; copy.warp[keyPath: path] = value
                let cg = renderer.render(copy, longEdge: 320)
                check(cg != nil && hash(cg!) != baseHash, "\(name) distortion")
                check(hash(renderer.render(copy, longEdge: 320, bypass: true)!) == baseHash, "\(name) before comparison")
            }
            var hidden = art; hidden.layers.append(Layer(name: "Hidden", material: .dots, visible: false))
            check(hash(renderer.render(hidden, longEdge: 320)!) == baseHash, "hidden layer has no effect")
            hidden.layers[1].visible = true; hidden.layers[1].opacity = 0
            check(hash(renderer.render(hidden, longEdge: 320)!) == baseHash, "zero opacity has no effect")
            var transformed = art; transformed.layers[0].rotation = 38; transformed.layers[0].scale = 0.7; transformed.layers[0].x = 0.2
            check(hash(renderer.render(transformed, longEdge: 320)!) != baseHash, "layer placement changes render")
            for (shape, width, height) in [("Portrait", 256, 320), ("Landscape", 320, 228)] {
                var a = art; a.aspect = shape; let cg = renderer.render(a, longEdge: 320)!
                check(cg.width == width && cg.height == height, "\(shape) canvas dimensions")
            }
            let studio = Studio(restoreSource: false); let starting = studio.art
            studio.addPattern(.dots); let after = studio.art
            studio.undo(); check(studio.art == starting, "undo restores experiment")
            studio.redo(); check(studio.art == after, "redo restores change")
            studio.newCanvas()
            check(studio.art.layers.isEmpty, "new canvas starts empty")
            studio.undo(); check(studio.art == after, "new canvas is undoable within the session")
            let actions = Studio(restoreSource: false)
            actions.newCanvas()
            for material in Material.allCases where material != .image {
                actions.addPattern(material)
                check(actions.current?.material == material, "\(material.label) button adds and selects its layer")
            }
            let beforeDuplicate = actions.art.layers
            let originalID = actions.selected
            actions.duplicate()
            check(actions.art.layers.count == beforeDuplicate.count + 1 && actions.selected != originalID,
                  "context-menu duplicate adds an independent selected layer")
            actions.duplicate()
            actions.undo()
            check(actions.art.layers.count == beforeDuplicate.count + 1, "one undo reverses one duplicate command")
            actions.undo()
            check(actions.art.layers == beforeDuplicate, "second undo reverses the earlier duplicate")
            actions.remove()
            let afterRemoval = actions.art.layers
            check(afterRemoval.count == beforeDuplicate.count - 1 && actions.current != nil,
                  "context-menu remove selects a remaining layer")
            actions.remove(); actions.undo()
            check(actions.art.layers == afterRemoval, "one undo reverses one remove command")
            actions.undo()
            check(actions.art.layers == beforeDuplicate, "removal restores all layer data on undo")
            for name in ["Flow", "Vortex", "Blocks"] {
                let beforePreset = actions.art
                actions.preset(name)
                check(actions.art != beforePreset, "\(name) preset changes the canvas")
                actions.undo()
                check(actions.art == beforePreset, "\(name) preset is undoable")
            }
            let warpDefaults: [(WritableKeyPath<Warp, Double>, Double)] = [
                (\.wave, 0), (\.twist, 0), (\.bulge, 0), (\.pixel, 0),
                (\.wavelength, 3), (\.saturation, 1), (\.contrast, 1)]
            for (path, expected) in warpDefaults {
                check(Warp()[keyPath: path] == expected, "canvas slider reset agrees with model default")
            }
            let layerDefaults: [(WritableKeyPath<Layer, Double>, Double)] = [
                (\.opacity, 1), (\.frequency, 12), (\.scale, 1), (\.rotation, 0), (\.x, 0), (\.y, 0)]
            for (path, expected) in layerDefaults {
                check(Layer(name: "Default", material: .stripes)[keyPath: path] == expected,
                      "layer slider reset agrees with model default")
            }
            let ordering = Studio(restoreSource: false)
            ordering.addPattern(.dots); ordering.addPattern(.checker)
            let originalLayers = ordering.art.layers
            let selectedLayer = ordering.selected
            ordering.reorderLayers(fromOffsets: IndexSet(integer: 0), toOffset: 4)
            let reordered = [originalLayers[3], originalLayers[0], originalLayers[1], originalLayers[2]]
            check(ordering.art.layers == reordered, "dragging the top row to the bottom updates compositing order")
            check(ordering.selected == selectedLayer, "reordering preserves the selected layer")
            ordering.undo(); check(ordering.art.layers == originalLayers, "one undo restores the full layer order")
            ordering.redo(); check(ordering.art.layers == reordered, "redo restores dragged layer order")
            ordering.reorderLayers(fromOffsets: IndexSet(integer: 3), toOffset: 0)
            check(ordering.art.layers == originalLayers, "dragging the bottom row to the top updates compositing order")
            ordering.undo(); check(ordering.art.layers == reordered, "consecutive drags have separate undo steps")
            let orderRevision = ordering.revision
            ordering.reorderLayers(fromOffsets: IndexSet(integer: 0), toOffset: 1)
            check(ordering.revision == orderRevision, "dropping a row in place does not create an edit")
            ordering.reorderLayers(fromOffsets: IndexSet(integer: 99), toOffset: 0)
            check(ordering.art.layers == reordered, "invalid drag offsets leave the artwork intact")
            art = starting
            let preview = renderer.render(art, longEdge: 1000)!
            try NSBitmapImageRep(cgImage: preview).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("preview.png"))
            let importer = Studio(restoreSource: false)
            let beforeImport = importer.art.layers.count
            importer.importImages([output.appendingPathComponent("preview.png")])
            waitFor { !importer.importing }
            check(importer.art.layers.count == beforeImport + 1 && importer.current?.image != nil, "image file imports as an embedded layer")
            check(importer.error == nil, "image import completes without error")
            let beforeProjectDrop = importer.art
            importer.importImages([output.appendingPathComponent("Old experiment.meld")])
            check(importer.art == beforeProjectDrop && importer.error != nil && !importer.importing,
                  "legacy project drops explain unsupported format without changing artwork")
            importer.error = nil
            let exportURL = output.appendingPathComponent("session-export.png")
            importer.export(to: exportURL)
            waitFor { !importer.exporting }
            check(importer.error == nil && FileManager.default.fileExists(atPath: exportURL.path), "session exports a PNG through the model")
            check(NSImage(contentsOf: exportURL) != nil, "session export opens as an image")
            let exported = renderer.render(art, longEdge: 2400)!
            check(exported.width == 2400 && exported.height == 2400, "full size export dimensions")
            let png = NSBitmapImageRep(cgImage: exported).representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent("export.png"))
            check(NSImage(data: png) != nil, "exported PNG can be reopened")
            let materials = output.appendingPathComponent("materials-\(UUID())", isDirectory: true)
            let nested = materials.appendingPathComponent("nested", isDirectory: true)
            let hiddenFolder = materials.appendingPathComponent(".hidden", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
            for name in ["one.png", "two.JPG", "three.png", "four.png"] { try sample.write(to: materials.appendingPathComponent(name)) }
            for name in ["five.png", "six.png"] { try sample.write(to: nested.appendingPathComponent(name)) }
            try sample.write(to: hiddenFolder.appendingPathComponent("hidden.png"))
            try Data("not an image".utf8).write(to: materials.appendingPathComponent("broken.CR3"))
            try Data("note".utf8).write(to: materials.appendingPathComponent("notes.txt"))
            try FileManager.default.createSymbolicLink(at: materials.appendingPathComponent("outside.png"), withDestinationURL: output.appendingPathComponent("preview.png"))
            try FileManager.default.createSymbolicLink(at: materials.appendingPathComponent("outside-folder"), withDestinationURL: output)
            let deep = try MaterialLoader.scan(materials)
            check(deep.urls.count == 7, "folder scan always includes subfolders and RAW candidates")
            check(deep.urls.allSatisfy { !$0.path.contains("hidden") && !$0.lastPathComponent.contains("outside") }, "scan skips hidden files and links outside the source")
            let loader = MaterialLoader()
            check(loader.load(materials.appendingPathComponent("broken.CR3")) == nil, "corrupt RAW file is rejected")
            let reduced = loader.load(output.appendingPathComponent("preview.png"), maximum: 160)!
            let smallSource = CGImageSourceCreateWithData(reduced.layer.image! as CFData, nil)!
            let smallImage = CGImageSourceCreateImageAtIndex(smallSource, 0, nil)!
            check(max(smallImage.width, smallImage.height) == 160, "source images decode to bounded working copies")
            let orientationURL = output.appendingPathComponent("orientation.jpg")
            let orientationContext = Renderer.canvas(w: 80, h: 40)!
            orientationContext.setFillColor(Ink(0.4, 0.2, 0.7).cg); orientationContext.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            let destination = CGImageDestinationCreateWithURL(orientationURL as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, orientationContext.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
            check(CGImageDestinationFinalize(destination), "orientation fixture writes")
            let oriented = loader.load(orientationURL)!
            let orientedSource = CGImageSourceCreateWithData(oriented.layer.image! as CFData, nil)!
            let orientedImage = CGImageSourceCreateImageAtIndex(orientedSource, 0, nil)!
            check(orientedImage.width == 40 && orientedImage.height == 80, "camera orientation is applied when importing")
            var originals: [URL: Data] = [:]
            for url in deep.urls { originals[url] = try Data(contentsOf: url) }
            let library = Studio(restoreSource: false); let originalArt = library.art
            library.setSourceFolder(materials, scan: false)
            check(library.sourceFolder == materials && !library.sourceScanning && library.sourceCount == 0,
                  "remembered source is available without an automatic scan")
            library.setSourceFolder(materials); waitFor { !library.sourceScanning }
            check(library.sourceCount == 7, "source folder appears in the model")
            library.randomize(); waitFor { !library.gathering }
            let mixed = library.art
            let picked = mixed.layers.filter { $0.material == .image }
            check((2...3).contains(picked.count) && picked.allSatisfy { $0.image != nil && $0.sourcePath != nil }, "Surprise me loads random source images")
            check(Set(picked.compactMap(\.sourcePath)).count == picked.count, "a composition never selects the same file twice")
            check(mixed.layers.contains { $0.material != .image }, "source compositions include a pattern")
            check(renderer.render(mixed, longEdge: 320) != nil, "folder composition renders")
            library.undo(); check(library.art == originalArt, "undo restores the canvas before folder surprise")
            library.redo(); check(library.art == mixed, "redo restores folder composition")
            let firstPaths = Set(picked.compactMap(\.sourcePath))
            library.randomize(); waitFor { !library.gathering }
            let secondPaths = Set(library.art.layers.filter { $0.material == .image }.compactMap(\.sourcePath))
            check(firstPaths.isDisjoint(with: secondPaths), "the next surprise favours unused material")
            library.refreshSource(); waitFor { !library.sourceScanning }
            check(library.sourceCount == 7, "manual rescan includes subfolders")
            library.randomize()
            library.change("intervening-edit") { $0.warp.twist = -4.5 }
            let edited = library.art; waitFor { !library.gathering }
            check(library.art == edited, "an in-flight surprise never overwrites newer edits")
            for (url, data) in originals { check(try Data(contentsOf: url) == data, "original \(url.lastPathComponent) stays unchanged") }
            let nestedOnly = output.appendingPathComponent("nested-only-\(UUID())", isDirectory: true)
            let deepFolder = nestedOnly.appendingPathComponent("one/two", isDirectory: true)
            try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
            try sample.write(to: deepFolder.appendingPathComponent("photo.png"))
            let nestedStudio = Studio(restoreSource: false)
            nestedStudio.setSourceFolder(nestedOnly); waitFor { !nestedStudio.sourceScanning }
            check(nestedStudio.sourceCount == 1, "source scan finds images two subfolders deep")
            nestedStudio.randomize(); waitFor { !nestedStudio.gathering }
            check(nestedStudio.error == nil && nestedStudio.art.layers.filter { $0.material == .image }.map(\.sourcePath) == [deepFolder.appendingPathComponent("photo.png").path],
                  "Surprise me uses images when only subfolders contain material")
            let empty = output.appendingPathComponent("empty-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            library.setSourceFolder(empty); waitFor { !library.sourceScanning }
            let beforeEmpty = library.art
            library.randomize(); waitFor { !library.gathering }
            check(library.art == beforeEmpty && library.error != nil, "empty folder explains the problem without changing artwork")
            library.error = nil
            library.setSourceFolder(empty.appendingPathComponent("missing")); waitFor { !library.sourceScanning }
            library.randomize(); waitFor { !library.gathering }
            check(library.art == beforeEmpty && library.error != nil, "missing folder leaves the artwork intact")
            library.clearSourceFolder()
            check(library.sourceFolder == nil && library.sourceCount == 0, "source folder can be disconnected")
            library.error = nil; library.randomize()
            check(library.art.layers.filter { $0.material == .image } == beforeEmpty.layers.filter { $0.material == .image }
                && library.art.layers.map(\.id) == beforeEmpty.layers.map(\.id), "without a folder Surprise me keeps current image material")
            if let rawPath = ProcessInfo.processInfo.environment["MELD_RAW_FIXTURE"] {
                let rawURL = URL(fileURLWithPath: rawPath)
                let rawOriginal = try Data(contentsOf: rawURL)
                guard let loaded = loader.load(rawURL) else { check(false, "real RAW fixture opens"); return }
                check(loaded.layer.name.contains("RAW") && loaded.layer.image != nil, "real Nikon NEF loads as an embedded image")
                print(loaded.usedRawPreview ? "RAW fixture used embedded preview fallback" : "RAW fixture developed with native decoder")
                check(try Data(contentsOf: rawURL) == rawOriginal, "RAW original remains unchanged")
                let rawFolder = output.appendingPathComponent("raw-only-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)
                try rawOriginal.write(to: rawFolder.appendingPathComponent("photo.NEF"))
                let rawStudio = Studio(restoreSource: false); rawStudio.setSourceFolder(rawFolder)
                waitFor { !rawStudio.sourceScanning }; rawStudio.randomize(); waitFor { !rawStudio.gathering }
                check(rawStudio.art.layers.filter { $0.material == .image }.count == 1 && rawStudio.error == nil, "Surprise me works in a RAW-only folder")
                check(renderer.render(rawStudio.art, longEdge: 320) != nil, "RAW-based experiment renders")
            }
            let c = Renderer.canvas(w: 1024, h: 1024)!
            c.addPath(CGPath(roundedRect: CGRect(x: 35, y: 35, width: 954, height: 954), cornerWidth: 205, cornerHeight: 205, transform: nil)); c.clip()
            c.setFillColor(Ink(0.13,0.17,0.28).cg); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            c.addPath(CGPath(roundedRect: CGRect(x: 98, y: 98, width: 828, height: 828), cornerWidth: 142, cornerHeight: 142, transform: nil)); c.clip()
            c.draw(preview, in: CGRect(x: 98, y: 98, width: 828, height: 828))
            try NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon.png"))
            print("All rendering and session checks passed.")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
