import AppKit
import ImageIO

/// Checks for the 0.6 workflow: kept picks, variations, keyboard navigation, studies, palette and sharing.
@MainActor
enum FeatureTests {
    static func run(output: URL) throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        func wait(_ condition: () -> Bool) {
            check(SelfTest.settle(condition, step: 0.005), "feature workflow settles")
        }
        func hash(_ image: CGImage) -> UInt64 {
            (image.dataProvider!.data! as Data).reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        func pixels(_ image: NSImage) -> NSBitmapImageRep { NSBitmapImageRep(data: image.tiffRepresentation!)! }

        let folder = output.appendingPathComponent("feature-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Renderer.starterPNG()!.write(to: folder.appendingPathComponent("study.png"))
        for (i, material) in [Material.stripes, .dots, .rings].enumerated() {
            let layer = Layer(name: material.label, material: material, frequency: Double(5 + i * 3),
                              ink: Ink(0.7 - Double(i) * 0.2, 0.25, 0.2 + Double(i) * 0.25), paper: Ink(0.95, 0.85, 0.6))
            try Renderer.normalizedPNG(Renderer.pattern(layer, w: 600, h: 600)!, maximum: 600)!
                .write(to: folder.appendingPathComponent("\(material.label).png"))
        }
        let studio = Studio(restoreSource: false, starter: false)
        studio.pasteboard = NSPasteboard(name: NSPasteboard.Name("studio.meld.tests.\(UUID().uuidString)"))
        studio.setSourceFolder(folder, scan: false)
        studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.trials.count == 36 && studio.groups.count == 1, "a first set forms one row of 36 previews")
        check(studio.trials.map(\.number) == Array(1...36), "a first set is numbered 1 to 36")

        // Picks survive a new set.
        let firstPicks = [studio.trials[3].id, studio.trials[20].id]
        firstPicks.forEach { studio.toggleFavourite($0) }
        let firstGroup = studio.groups[0]
        studio.makeTrials(); wait { !studio.makingTrials }
        check(studio.trials.count == 38 && Set(firstPicks).isSubset(of: Set(studio.trials.map(\.id))) && studio.favouriteTrials == Set(firstPicks),
              "a new set keeps earlier picks and replaces everything else")
        check(studio.groups.count == 2 && studio.groups[1] == firstGroup && studio.groups[0].title.hasPrefix("Set 2"),
              "the new set appears first, with kept picks in their earlier row")
        check(Set(studio.trials.map(\.number)).count == 38 && studio.trials.filter { $0.group == studio.groups[0].id }.map(\.number) == Array(37...72),
              "preview numbers stay unique across sets")
        check(studio.orderedTrials.prefix(36).allSatisfy { $0.group == studio.groups[0].id } && studio.orderedTrials.count == 38,
              "grid order lists the newest row first")

        // Keyboard selection.
        studio.gridSelection = nil
        studio.moveSelection(by: 1)
        check(studio.gridSelection == studio.orderedTrials[0].id, "the first arrow press selects the first preview")
        studio.moveSelectionVertically(1, columns: 5)
        check(studio.gridSelection == studio.orderedTrials[5].id, "down arrow moves one row in the same column")
        studio.moveSelection(by: -1)
        check(studio.gridSelection == studio.orderedTrials[4].id, "left arrow moves to the previous preview")
        studio.gridSelection = studio.orderedTrials[32].id // last row of the newest set: 30...35
        studio.moveSelectionVertically(1, columns: 6)
        check(studio.gridSelection == studio.orderedTrials[37].id, "down arrow continues into the next row, clamping its column")
        studio.moveSelection(by: 100)
        check(studio.gridSelection == studio.orderedTrials.last!.id, "selection stops at the last preview")
        studio.gridSelection = studio.orderedTrials[1].id
        studio.setPick(studio.orderedTrials[1].id, true); studio.setPick(studio.orderedTrials[1].id, true)
        check(studio.favouriteTrials.contains(studio.orderedTrials[1].id) && studio.favouriteTrials.count == 3, "F picks without toggling twice")
        studio.setPick(studio.orderedTrials[1].id, false)
        check(studio.favouriteTrials.count == 2, "D removes a pick")

        let savedSize = UserDefaults.standard.object(forKey: "grid.thumbnailSize") as? Double
        studio.zoomThumbnails(1); studio.zoomThumbnails(5)
        check(studio.thumbnailSize == Studio.thumbnailSizes.last, "thumbnail zoom stops at the sharpest large size")
        studio.zoomThumbnails(-9)
        check(studio.thumbnailSize == Studio.thumbnailSizes.first, "thumbnail zoom stops at the smallest size")
        check(UserDefaults.standard.object(forKey: "grid.thumbnailSize") as? Double == savedSize,
              "test sessions leave the saved thumbnail size alone")
        studio.zoomThumbnails(1)

        // Refinement navigation follows the visible order.
        let ordered = studio.orderedTrials
        studio.openTrial(ordered[0].id)
        check(!studio.canOpenPrevious && studio.canOpenNext, "the first preview has only a next neighbour")
        studio.openAdjacentTrial(1)
        check(studio.activeTrialID == ordered[1].id && studio.stage == .refine && !studio.canUndo, "next preview opens with its own history")
        studio.showTrials()
        check(studio.gridSelection == ordered[1].id, "returning to the grid selects the refined preview")
        studio.picksOnly = true
        studio.openTrial(firstPicks[0])
        studio.openAdjacentTrial(1)
        check(studio.activeTrialID == firstPicks[1] && !studio.canOpenNext, "with Picks shown, navigation moves only between picks")
        studio.setPick(firstPicks[1], false)
        check(studio.activeTrialID == firstPicks[1] && studio.canOpenPrevious && !studio.canOpenNext,
              "removing the open preview's pick keeps previous/next working")
        studio.setPick(firstPicks[1], true)
        studio.showTrials()
        studio.gridSelection = firstPicks[0]
        studio.setPick(firstPicks[0], false)
        check(studio.gridSelection == firstPicks[1], "unpicking a hidden selection moves it to the nearest visible pick")
        studio.setPick(firstPicks[0], true)
        studio.picksOnly = false
        studio.gridSelection = ordered[5].id
        studio.picksOnly = true
        check(studio.gridSelection.map { studio.favouriteTrials.contains($0) } == true, "showing picks keeps a visible selection")
        studio.picksOnly = false
        studio.chooseMaterial()
        check(studio.commandTarget == nil && !studio.canMakeVariations, "menu commands have no hidden target at source selection")
        studio.showTrials()
        studio.openTrial(firstPicks[1])

        // Value studies change only the displayed preview.
        studio.change("saturation") { $0.warp.saturation = 1.6 }
        wait { !studio.rendering }
        let artBefore = studio.art
        check(!studio.palette.isEmpty && studio.palette.count <= 5, "refinement shows the preview's main colours")
        studio.setStudy(.values); wait { !studio.rendering }
        let mono = pixels(studio.preview!)
        check([(0.2, 0.3), (0.5, 0.5), (0.7, 0.8)].allSatisfy { u, v in
            let c = mono.colorAt(x: Int(u * Double(mono.pixelsWide)), y: Int(v * Double(mono.pixelsHigh)))!.usingColorSpace(.sRGB)!
            return abs(c.redComponent - c.greenComponent) < 0.02 && abs(c.greenComponent - c.blueComponent) < 0.02
        } && studio.art == artBefore && !studio.canRedo, "Values view shows greyscale without editing the artwork")
        check(studio.palette.contains { max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) > 0.08 }, "the palette stays in colour during a value study")
        studio.setStudy(.notan); wait { !studio.rendering }
        let notan = pixels(studio.preview!)
        var levels = Set<Int>()
        for x in stride(from: 3, to: notan.pixelsWide, by: 37) { for y in stride(from: 5, to: notan.pixelsHigh, by: 41) {
            levels.insert(Int((notan.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent * 10).rounded()))
        }}
        check(levels.count <= 3, "Notan simplifies the preview into three values")
        let exportedArt = studio.art
        studio.setStudy(.colour); wait { !studio.rendering }
        check(studio.art == exportedArt, "switching studies never changes the export")
        check(Ink(1, 0, 0).hex == "#FF0000" && Ink(0.5, 0.25, 1).hex == "#8040FF", "palette colours copy as hex values")

        // Variations come from the session's decoded images, including adjustments.
        let base = studio.activeTrial!
        let edited = studio.art
        let groupsBefore = studio.groups.count, countBefore = studio.trials.count
        studio.setSourceFolder(folder.appendingPathComponent("disconnected"), scan: false)
        studio.makeVariations(of: base.id); wait { !studio.makingTrials }
        let variations = studio.trials.filter { $0.group == studio.groups[0].id }
        check(studio.error == nil && studio.groups.count == groupsBefore + 1 && variations.count == 12 && studio.trials.count == countBefore + 12,
              "variations add a row of 12 without reading the source folder")
        check(studio.stage == .previews && studio.groups[0].title == "Variations of \(base.title)", "variations open in the grid under their own heading")
        check(Set(variations.map { hash($0.thumbnail) }).count == 12, "all variations differ")
        check(variations.allSatisfy { $0.style == base.style && $0.art.aspect == base.art.aspect && $0.art.layers.count == edited.layers.count },
              "variations keep the recipe, shape and layer structure")
        check(variations.allSatisfy { abs($0.art.warp.saturation - edited.warp.saturation) <= 0.3 + 1e-9 },
              "variations start from the refined adjustments")
        check(variations.allSatisfy { $0.art.layers.filter { $0.material == .image }.allSatisfy { $0.image != nil } }, "variations keep editable images")
        let pool = studio.trials.flatMap { $0.art.layers.filter { $0.material == .image } }.map(PreparedMaterial.init)
        let renderer = Renderer()
        let a = TrialGenerator.vary(edited, materials: pool, seed: 7), b = TrialGenerator.vary(edited, materials: pool, seed: 7)
        let c = TrialGenerator.vary(edited, materials: pool, seed: 8)
        check(hash(renderer.render(a, longEdge: 240)!) == hash(renderer.render(b, longEdge: 240)!), "a variation seed reproduces its image")
        check(hash(renderer.render(a, longEdge: 240)!) != hash(renderer.render(c, longEdge: 240)!), "different variation seeds differ")
        let keptIDs = studio.trials.map(\.id)
        studio.makeVariations(of: variations[0].id, count: 40); wait { studio.trialProgress > 0 || !studio.makingTrials }
        studio.cancelTrials()
        let partial = studio.trials.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(partial > keptIDs.count && partial < keptIDs.count + 40 && studio.trials.count == partial && Set(keptIDs).isSubset(of: Set(studio.trials.map(\.id))),
              "stopping variations keeps finished ones and every earlier preview")

        // Sharing: export names stay unique across rows, copy and drag produce full-size PNGs.
        studio.setSourceFolder(folder, scan: false)
        studio.showTrials()
        studio.toggleFavourite(variations[0].id)
        let picks = studio.trials.filter { studio.favouriteTrials.contains($0.id) }
        let exports = output.appendingPathComponent("feature-exports", isDirectory: true)
        try? FileManager.default.removeItem(at: exports)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        studio.exportTrials(picks, to: exports); wait { !studio.exportingTrials }
        let exportFolder = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil).first!
        let exported = try FileManager.default.contentsOfDirectory(atPath: exportFolder.path)
        check(studio.error == nil && exported.count == picks.count + 1, "picks from different rows export without name collisions")
        check(exportFolder.lastPathComponent.range(of: #"^Meld picks \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2} "#, options: .regularExpression) != nil,
              "export folder names use a 24-hour time regardless of the user's clock setting")
        studio.copyImage(of: variations[1].id); wait { !studio.copying }
        let copied = studio.pasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
        check(copied.map { max($0.pixelsWide, $0.pixelsHigh) == 2400 } == true && studio.pasteboard.data(forType: .tiff) != nil,
              "Copy Image places a full-size PNG on the pasteboard")
        let provider = studio.dragProvider(for: variations[2].id)
        var dragged: URL?, dragFinished = false
        _ = provider.loadFileRepresentation(forTypeIdentifier: "public.png") { url, _ in
            if let url {
                let copy = output.appendingPathComponent("dragged.png")
                try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: url, to: copy); dragged = copy
            }
            DispatchQueue.main.async { dragFinished = true }
        }
        wait { dragFinished }
        let draggedImage = dragged.flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data()) }
        check(draggedImage.map { max($0.pixelsWide, $0.pixelsHigh) == 2400 } == true && provider.suggestedName?.hasPrefix("Meld ") == true,
              "dragging a preview provides a full-size PNG file")
    }
}
