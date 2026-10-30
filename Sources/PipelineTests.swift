import AppKit
import ImageIO
import Darwin

/// Checks for the concurrent decode, preview and export pipeline.
@MainActor
enum PipelineTests {
    static func run(output: URL) throws {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(60)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            check(condition(), "pipeline operation settles")
        }
        func footprint() -> Double {
            var info = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            return Double(info.ri_phys_footprint) / 1_000_000
        }
        func rgba(_ image: CGImage) -> [UInt8] {
            let context = Renderer.canvas(w: image.width, h: image.height)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> (mean: Double, max: Int) {
            var sum = 0, worst = 0
            for i in a.indices { let d = abs(Int(a[i]) - Int(b[i])); sum += d; worst = max(worst, d) }
            return (Double(sum) / Double(a.count), worst)
        }
        func hash(_ image: CGImage) -> UInt64 {
            (image.dataProvider!.data! as Data).reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }

        // Ordered concurrency: results keep index order and stopping starts nothing new.
        var delivered: [Int] = []
        Concurrent.ordered(40, width: 4, stop: { false }) { i -> Int in
            usleep(UInt32((i * 7) % 5) * 1000); return i * 2
        } deliver: { _, value in delivered.append(value) }
        check(delivered == (0..<40).map { $0 * 2 }, "concurrent work delivers its results in index order")
        let stopLock = NSLock()
        var stopNow = false, started: [Int] = [], finished: [Int] = []
        Concurrent.ordered(100, width: 4, stop: { stopLock.lock(); defer { stopLock.unlock() }; return stopNow }) { i -> Int in
            stopLock.lock(); started.append(i); if i == 10 { stopNow = true }; stopLock.unlock()
            usleep(2000); return i
        } deliver: { i, _ in finished.append(i) }
        check(started.count < 100 && finished == Array(0..<started.count) && Set(started) == Set(finished),
              "stopping concurrent work delivers every started item in order and starts no more")

        // Decoding ahead keeps the serial pool: the first usable candidates in sampled order.
        let folder = output.appendingPathComponent("pipeline-sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var candidates: [URL] = [], usable: [String] = []
        for (i, kind) in ["ok", "bad", "ok", "ok", "bad", "ok", "ok", "ok", "bad", "ok"].enumerated() {
            let url = folder.appendingPathComponent("candidate-\(i).\(kind == "ok" ? "png" : "NEF")")
            if kind == "ok" {
                let layer = Layer(name: "p", material: [Material.stripes, .checker, .dots, .rings][i % 4], frequency: Double(4 + i),
                                  ink: Ink(0.1 + Double(i) * 0.08, 0.25, 0.4), paper: Ink(0.92, 0.8 - Double(i) * 0.05, 0.5))
                try Renderer.normalizedPNG(Renderer.pattern(layer, w: 900, h: 600)!, maximum: 900)!.write(to: url)
                usable.append(url.path)
            } else { try Data("not an image".utf8).write(to: url) }
            candidates.append(url)
        }
        let gatherer = MaterialGatherer(candidates, wanted: 5, workers: 3, loader: MaterialLoader(), cancelled: { false }) { _ in }
        check(gatherer.pool(atLeast: 3).map { $0.layer.sourcePath! } == Array(usable.prefix(3)),
              "the first preview group uses the first three usable sources in sampled order")
        check(gatherer.pool(atLeast: 5).map { $0.layer.sourcePath! } == Array(usable.prefix(5))
              && gatherer.pool(atLeast: 9).count == 5,
              "later groups broaden the pool in order, up to its bound")
        check(gatherer.skipped == 2, "decoding ahead stops at the pool bound and counts each unreadable file once")
        let stopped = CancellableJob(); stopped.cancel()
        let cancelStart = Date()
        let cancelledGatherer = MaterialGatherer(candidates, wanted: 5, workers: 3, loader: MaterialLoader(), cancelled: { stopped.cancelled }) { _ in }
        check(cancelledGatherer.pool(atLeast: 3).isEmpty && Date().timeIntervalSince(cancelStart) < 1,
              "a cancelled gatherer returns without decoding")

        // Mirrored tiles shrink their cell before tiling instead of holding full-size copies.
        let sources: [PreparedMaterial] = (0..<3).map { i in
            let pattern = Layer(name: "t", material: [Material.stripes, .checker, .dots][i], frequency: Double(5 + i * 3),
                                ink: Ink(0.2, 0.3 + Double(i) * 0.2, 0.5), paper: Ink(0.9, 0.7, 0.4 + Double(i) * 0.1))
            var image = Layer(name: "source \(i)", material: .image, image: SourceImage(Renderer.pattern(pattern, w: 2400, h: 1600)!))
            image.sourcePath = "/synthetic/\(i)"
            return PreparedMaterial(image)
        }
        let renderer = Renderer()
        let before = footprint()
        for i in 0..<12 {
            _ = autoreleasepool { renderer.render(TrialGenerator.compose(sources, style: .tiles, aspect: ["Square", "Portrait", "Landscape"][i % 3], seed: UInt64(i + 1)), longEdge: 480) }
        }
        check(footprint() - before < 400, "twelve tiled previews stay within a bounded footprint")
        var tiled = TrialGenerator.compose(sources, style: .tiles, aspect: "Landscape", seed: 5)
        tiled.warp = Warp()
        let small = renderer.render(tiled, longEdge: 480)!, full = renderer.render(tiled, longEdge: 2400)!
        let reduced = Renderer.canvas(w: small.width, h: small.height)!
        reduced.interpolationQuality = .high; reduced.draw(full, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let tileDifference = meanDifference(rgba(small), rgba(reduced.makeImage()!))
        print(String(format: "  tiled preview vs reduced export: mean difference %.2f/255", tileDifference.mean))
        check(tileDifference.mean < 8, "mirrored tiles keep the same layout at preview and export sizes")
        let wave = Renderer.waveMap(w: 2400, h: 1600, frequency: 3)!
        check(wave.extent == CGRect(x: 0, y: 0, width: 2400, height: 1600), "wave displacement map covers the full canvas")

        // A generated set keeps numbering, balance and progressive delivery under concurrency.
        let setFolder = output.appendingPathComponent("pipeline-set", isDirectory: true)
        try FileManager.default.createDirectory(at: setFolder, withIntermediateDirectories: true)
        for (i, source) in sources.enumerated() { try Renderer.normalizedPNG(source.layer.image!.pixels, maximum: 2400)!.write(to: setFolder.appendingPathComponent("s\(i).png")) }
        for url in candidates where url.pathExtension == "png" { try FileManager.default.copyItem(at: url, to: setFolder.appendingPathComponent(url.lastPathComponent)) }
        let studio = Studio(restoreSource: false, starter: false)
        studio.setSourceFolder(setFolder, scan: false)
        studio.makeTrials()
        var sawPartial = false
        wait {
            if studio.makingTrials && (1..<36).contains(studio.trials.count) { sawPartial = true }
            return !studio.makingTrials
        }
        check(sawPartial, "previews appear progressively while the rest of the set renders")
        check(studio.error == nil && studio.trials.map(\.number) == Array(1...36), "concurrent previews keep their numbering and order")
        check(Set(studio.trials.map { hash($0.thumbnail) }).count == 36
              && CompositionStyle.allCases.allSatisfy { style in studio.trials.filter { $0.style == style }.count == 6 },
              "concurrent generation keeps 36 distinct previews with six of each style")

        // Parallel export writes the same pixels as a serial render, in the chosen order.
        let picks = Array(studio.trials.prefix(8).reversed())
        let exportFolder = output.appendingPathComponent("pipeline-export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        var reported: [Int] = []
        let outcome = TrialExporter.write(picks, into: exportFolder, renderer: Renderer(), cancelled: { false }) { reported.append($0) }
        check(outcome.failure == nil && outcome.exported.map(\.id) == picks.map(\.id) && reported == Array(1...8),
              "parallel export returns picks in their chosen order with steady progress")
        let serial = Renderer()
        var identical = true
        for trial in picks {
            let url = exportFolder.appendingPathComponent("\(trial.title).png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let written = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let expected = serial.render(trial.art, longEdge: 2400), written.width == expected.width, written.height == expected.height
            else { identical = false; continue }
            let difference = meanDifference(rgba(written), rgba(expected))
            if difference.max > 1 { identical = false }
        }
        check(identical, "parallel export matches serial rendering pixel for pixel")
        check(outcome.exported.allSatisfy { max($0.thumbnail.width, $0.thumbnail.height) == 480 },
              "contact sheet thumbnails come from the exported pixels")

        // Cancellation mid-batch keeps finished files and allows no late writes.
        let cancelExports = output.appendingPathComponent("pipeline-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelExports, withIntermediateDirectories: true)
        studio.exportTrials(studio.trials, to: cancelExports)
        wait { studio.trialExportProgress >= 2 || !studio.exportingTrials }
        studio.cancelTrialExport(); wait { !studio.exportingTrials }
        let batch = try FileManager.default.contentsOfDirectory(at: cancelExports, includingPropertiesForKeys: nil).first!
        let saved = try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let later = try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil)
        let titles = Set(studio.trials.map { "\($0.title).png" } + ["Contact sheet.png"])
        check(studio.trialExportProgress < 36 && saved.count == studio.trialExportProgress + 1 && later.count == saved.count
              && saved.allSatisfy { titles.contains($0.lastPathComponent) },
              "cancelling a parallel export keeps finished PNGs and their contact sheet with no late writes")
        let name = batch.lastPathComponent
        check(name.range(of: #"^Meld picks \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2} [0-9A-F]{6}$"#, options: .regularExpression) != nil,
              "export folder names use a 24-hour time regardless of the clock setting")
    }
}
