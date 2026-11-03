import AppKit
import Darwin

/// `Meld --benchmark <folder> [runs]` times real model operations on a folder without
/// touching saved preferences. Source files are only read. Run `n` always uses the same
/// seeds, so separate invocations (and builds) repeat the same work.
@MainActor
enum Benchmark {
    /// Current and lifetime peak physical footprint, in MB.
    nonisolated static func footprint() -> (now: Double, peak: Double) {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return (Double(info.ri_phys_footprint) / 1_000_000, Double(info.ri_lifetime_max_phys_footprint) / 1_000_000)
    }

    static func run() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--benchmark"), i + 1 < args.count else {
            fputs("usage: Meld --benchmark <folder> [runs]\n", stderr); exit(2)
        }
        let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let runs = i + 2 < args.count ? max(1, Int(args[i + 2]) ?? 3) : 3
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("meld-benchmark-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(300)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        }
        func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }
        func mb(_ value: Double) -> String { String(format: "%.0f MB", value) }
        var firsts: [TimeInterval] = [], alls: [TimeInterval] = [], exports: [TimeInterval] = [], opens: [TimeInterval] = [], varies: [TimeInterval] = []
        var single: [TimeInterval] = []
        for run in 1...runs {
            let studio = Studio(restoreSource: false, starter: false)
            var seeds = RecipeRandom(seed: UInt64(run))
            studio.nextSeed = { seeds.next() }
            studio.setSourceFolder(folder, scan: false)
            let start = Date()
            studio.makeTrials()
            wait { !studio.trials.isEmpty || !studio.makingTrials }
            let first = Date().timeIntervalSince(start)
            wait { !studio.makingTrials }
            let all = Date().timeIntervalSince(start)
            guard studio.trials.count == 36 else { fputs("FAIL: \(studio.trials.count) previews; \(studio.error ?? "")\n", stderr); exit(1) }
            let afterSet = footprint()
            let openStart = Date()
            studio.openTrial(studio.trials[0].id)
            wait { !studio.rendering }
            let open = Date().timeIntervalSince(openStart)
            let singleStart = Date()
            studio.export(to: output.appendingPathComponent("single-\(run).png"))
            wait { !studio.exporting }
            let exportOne = Date().timeIntervalSince(singleStart)
            studio.showTrials()
            for trial in studio.trials.prefix(6) { studio.toggleFavourite(trial.id) }
            let picks = studio.trials.filter { studio.favouriteTrials.contains($0.id) }
            let exportStart = Date()
            studio.exportTrials(picks, to: output)
            wait { !studio.exportingTrials }
            let export = Date().timeIntervalSince(exportStart)
            let afterExport = footprint()
            let varyStart = Date()
            studio.makeVariations(of: studio.trials[0].id)
            wait { !studio.makingTrials }
            let vary = Date().timeIntervalSince(varyStart)
            guard studio.trials.count == 48 else { fputs("FAIL: variations produced \(studio.trials.count - 36)\n", stderr); exit(1) }
            firsts.append(first); alls.append(all); exports.append(export); opens.append(open); varies.append(vary); single.append(exportOne)
            print("run \(run): first \(ms(first)) · 36 previews \(ms(all)) · open \(ms(open)) · export 1 \(ms(exportOne)) · export 6 \(ms(export)) · 12 variations \(ms(vary))"
                  + " · peak after set \(mb(afterSet.peak)), after exports \(mb(afterExport.peak)), now \(mb(footprint().now))")
        }
        func median(_ v: [TimeInterval]) -> String { ms(v.sorted()[v.count / 2]) }
        print("median: first \(median(firsts)) · 36 previews \(median(alls)) · open \(median(opens)) · export 1 \(median(single)) · export 6 \(median(exports)) · 12 variations \(median(varies))")
        print("peak footprint: \(mb(footprint().peak))")
        try? FileManager.default.removeItem(at: output)
        exit(0)
    }
}
