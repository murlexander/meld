import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decodes sampled candidates a few at a time, ahead of the preview renderer.
///
/// The pool keeps candidate order: asking for `k` materials always returns the first
/// `k` usable candidates, exactly what a one-at-a-time decode would produce. Recipes
/// and the progressive pool growth between groups therefore keep their meaning; only
/// the waiting changes. At most `wanted` decodes succeed, so memory stays bounded by
/// the same pool size as before.
final class MaterialGatherer {
    private enum Outcome { case pending, usable(PreparedMaterial), unreadable, cancelled }
    private let candidates: [URL]
    private let wanted: Int
    private let loader: MaterialLoader
    private let cancelled: () -> Bool
    private let progress: (Int) -> Void
    private let condition = NSCondition()
    private var outcomes: [Outcome]
    private var claimed = 0, inFlight = 0, usable = 0

    /// `progress` receives the usable count, in increasing order, while the gatherer's lock is held.
    init(_ candidates: [URL], wanted: Int, workers: Int, loader: MaterialLoader,
         cancelled: @escaping () -> Bool, progress: @escaping (Int) -> Void) {
        self.candidates = candidates; self.wanted = max(0, wanted); self.loader = loader
        self.cancelled = cancelled; self.progress = progress
        outcomes = Array(repeating: .pending, count: candidates.count)
        for _ in 0..<max(1, workers) {
            DispatchQueue.global(qos: .userInitiated).async { self.work() }
        }
    }

    private func work() {
        condition.lock()
        while !cancelled(), claimed < candidates.count, usable < wanted {
            // Never decode more than the pool can use; a failure frees a slot.
            if usable + inFlight >= wanted { condition.wait(); continue }
            let index = claimed; claimed += 1; inFlight += 1
            condition.unlock()
            let material: PreparedMaterial? = autoreleasepool {
                guard let loaded = loader.load(candidates[index], maximum: 2400, cancelled: cancelled), !cancelled() else { return nil }
                return PreparedMaterial(loaded.layer)
            }
            condition.lock()
            inFlight -= 1
            if let material { outcomes[index] = .usable(material); usable += 1; progress(usable) }
            else { outcomes[index] = cancelled() ? .cancelled : .unreadable }
            condition.broadcast()
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until the first `target` usable candidates are known, the candidates
    /// run out, or the batch is cancelled; returns them in sampled order.
    func pool(atLeast target: Int) -> [PreparedMaterial] {
        let target = min(wanted, target)
        condition.lock(); defer { condition.unlock() }
        while true {
            var pool: [PreparedMaterial] = [], waiting = false
            for outcome in outcomes where pool.count < target {
                if case .usable(let material) = outcome { pool.append(material) }
                else if case .pending = outcome { waiting = true; break }
            }
            if pool.count == target || !waiting || cancelled() { return pool }
            // Poll so cancellation is noticed even when no decode is in flight.
            condition.wait(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Candidates that were decoded and turned out unusable.
    var skipped: Int {
        condition.lock(); defer { condition.unlock() }
        return outcomes.reduce(0) { count, outcome in
            if case .unreadable = outcome { return count + 1 }
            return count
        }
    }
}

enum Concurrent {
    /// Runs `work` for `0..<count` on up to `width` threads, claiming indices in order and
    /// making no new claims once `stop()` is true. Results reach `deliver` in index order,
    /// each as soon as every earlier index has finished; every claimed index is delivered.
    /// `deliver` runs under an internal lock, so it should only record or dispatch.
    static func ordered<T>(_ count: Int, width: Int, stop: () -> Bool,
                           work: (Int) -> T, deliver: (Int, T) -> Void) {
        guard count > 0 else { return }
        let lock = NSLock()
        var next = 0, flushed = 0
        var finished = [T?](repeating: nil, count: count)
        DispatchQueue.concurrentPerform(iterations: min(max(1, width), count)) { _ in
            while true {
                lock.lock()
                guard next < count, !stop() else { lock.unlock(); return }
                let index = next; next += 1
                lock.unlock()
                let result = work(index)
                lock.lock()
                finished[index] = result
                while flushed < count, let ready = finished[flushed] {
                    finished[flushed] = nil
                    deliver(flushed, ready)
                    flushed += 1
                }
                lock.unlock()
            }
        }
    }
}

enum PNGExport {
    /// Thread-safe ImageIO encoding; produces the same bytes as NSBitmapImageRep's PNG.
    static func data(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

enum TrialExporter {
    struct Outcome {
        /// Written trials in their chosen order, with thumbnails from the exported pixels.
        var exported: [Trial] = []
        var failure: Error?
    }

    /// Renders and writes 2400-pixel PNGs a few at a time. Cancellation stops new work
    /// and is checked again before encoding and writing; finished files are kept.
    static func write(_ chosen: [Trial], into folder: URL, renderer: Renderer, width: Int = 4,
                      cancelled: () -> Bool, progress: (Int) -> Void) -> Outcome {
        var outcome = Outcome()
        // PNG compression is the slow, CPU-bound part, so several encode at once. Renders
        // take turns: each concurrent GPU render grew the retained footprint by about 250 MB.
        let renderLane = NSLock()
        Concurrent.ordered(chosen.count, width: width, stop: { cancelled() || outcome.failure != nil }) { i -> Result<Trial?, Error> in
            Result { try autoreleasepool { try export(chosen[i], into: folder, renderer: renderer, renderLane: renderLane, cancelled: cancelled) } }
        } deliver: { _, result in
            switch result {
            case .success(let trial?): outcome.exported.append(trial); progress(outcome.exported.count)
            case .success(nil): break
            case .failure(let error): if outcome.failure == nil { outcome.failure = error }
            }
        }
        return outcome
    }

    private static func export(_ trial: Trial, into folder: URL, renderer: Renderer, renderLane: NSLock,
                               cancelled: () -> Bool) throws -> Trial? {
        if cancelled() { return nil }
        renderLane.lock()
        let rendered = renderer.render(trial.art, longEdge: 2400)
        renderLane.unlock()
        guard let cg = rendered else { throw CocoaError(.fileWriteUnknown) }
        if cancelled() { return nil }
        guard let png = PNGExport.data(cg) else { throw CocoaError(.fileWriteUnknown) }
        if cancelled() { return nil }
        try png.write(to: folder.appendingPathComponent("\(trial.title).png"), options: .withoutOverwriting)
        var copy = trial
        let scale = min(1, 480 / Double(max(cg.width, cg.height)))
        if let ctx = Renderer.canvas(w: max(1, Int(Double(cg.width) * scale)), h: max(1, Int(Double(cg.height) * scale))) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if let thumbnail = ctx.makeImage() { copy.thumbnail = thumbnail }
        }
        return copy
    }
}
