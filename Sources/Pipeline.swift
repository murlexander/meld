import AppKit
import ImageIO
import UniformTypeIdentifiers
import zlib

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
    /// PNG bytes for an image. Renders (opaque 8-bit sRGB RGBA) are compressed in strips on
    /// several threads; anything else goes through ImageIO.
    static func data(_ image: CGImage) -> Data? {
        stripped(image) ?? imageIO(image)
    }
    /// Thread-safe ImageIO encoding; produces the same bytes as NSBitmapImageRep's PNG.
    static func imageIO(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The PNG ImageIO writes for a render (RGBA, the sRGB chunk, Exif colour space and size,
    /// zlib level 1) with identical pixels, but compressed as in pigz: horizontal strips are
    /// filtered and deflated independently on several threads, and joined by sync flushes into
    /// one zlib stream, each strip in its own IDAT chunk. Rows use the Up filter. ImageIO took
    /// about 120 ms for a 2400-pixel image on one thread; this takes about 20 ms. Returns nil
    /// for any other kind of image, including any with transparency.
    static func stripped(_ image: CGImage, strips: Int = 16) -> Data? {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.name == CGColorSpace.sRGB,
              image.alphaInfo == .premultipliedLast || image.alphaInfo == .last,
              order == [] || order == .byteOrder32Big, !image.bitmapInfo.contains(.floatComponents),
              let pixels = image.dataProvider?.data, let base = CFDataGetBytePtr(pixels) else { return nil }
        let w = image.width, h = image.height, stride = image.bytesPerRow, rowBytes = w * 4
        guard w > 0, h > 0, stride >= rowBytes, CFDataGetLength(pixels) >= stride * (h - 1) + rowBytes else { return nil }
        let count = min(strips, h)
        var parts = [Data?](repeating: nil, count: count), checksums = [uLong](repeating: 0, count: count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: count) { s in
            let first = h * s / count, last = h * (s + 1) / count, size = (last - first) * (rowBytes + 1)
            let filtered = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { filtered.deallocate() }
            for y in first..<last {
                let row = base + y * stride, out = filtered + (y - first) * (rowBytes + 1)
                // Transparent pixels would need unpremultiplying; leave those images to ImageIO.
                var alpha: UInt32 = 0xFFFF_FFFF
                row.withMemoryRebound(to: UInt32.self, capacity: w) { p in for x in 0..<w { alpha &= p[x] } }
                guard UInt32(bigEndian: alpha) & 0xFF == 0xFF else { return }
                out[0] = 2
                if y == 0 { (out + 1).update(from: row, count: rowBytes) }
                else { let above = row - stride; for i in 0..<rowBytes { out[1 + i] = row[i] &- above[i] } }
            }
            var stream = z_stream()
            guard deflateInit2_(&stream, 1, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
            defer { deflateEnd(&stream) }
            var output = Data(count: Int(deflateBound(&stream, uLong(size))) + 16)
            let finish = s == count - 1
            let status: Int32 = output.withUnsafeMutableBytes { out in
                stream.next_in = filtered; stream.avail_in = uInt(size)
                stream.next_out = out.baseAddress!.assumingMemoryBound(to: Bytef.self); stream.avail_out = uInt(out.count)
                let status = deflate(&stream, finish ? Z_FINISH : Z_SYNC_FLUSH)
                return stream.avail_in == 0 && stream.avail_out > 0 ? status : Z_BUF_ERROR
            }
            guard status == (finish ? Z_STREAM_END : Z_OK) else { return }
            output.count = Int(stream.total_out)
            let checksum = adler32(1, filtered, uInt(size))
            lock.lock(); parts[s] = output; checksums[s] = checksum; lock.unlock()
        }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        var adler = checksums[0]
        for s in 1..<count { adler = adler32_combine(adler, checksums[s], (h * (s + 1) / count - h * s / count) * (rowBytes + 1)) }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            png.append(contentsOf: be32(body.count))
            let start = png.count
            png.append(contentsOf: Array(type.utf8)); png.append(body)
            let crc = png[start...].withUnsafeBytes { crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
            png.append(contentsOf: be32(Int(crc)))
        }
        chunk("IHDR", Data(be32(w) + be32(h) + [8, 6, 0, 0, 0]))
        chunk("sRGB", Data([0]))
        // A big-endian TIFF header and an Exif IFD: colour space sRGB, pixel width and height.
        chunk("eXIf", Data([0x4D, 0x4D, 0, 0x2A, 0, 0, 0, 8, 0, 1, 0x87, 0x69, 0, 4, 0, 0, 0, 1, 0, 0, 0, 0x1A, 0, 0, 0, 0,
                            0, 3, 0xA0, 0x01, 0, 3, 0, 0, 0, 1, 0, 1, 0, 0, 0xA0, 0x02, 0, 4, 0, 0, 0, 1] + be32(w)
                           + [0xA0, 0x03, 0, 4, 0, 0, 0, 1] + be32(h) + [0, 0, 0, 0]))
        for s in 0..<count {
            var body = s == 0 ? Data([0x78, 0x01]) : Data()
            body.append(parts[s]!)
            if s == count - 1 { body.append(contentsOf: be32(Int(adler))) }
            chunk("IDAT", body)
        }
        chunk("IEND", Data())
        return png
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
    static func write(_ chosen: [Trial], into folder: URL, width: Int = 3,
                      cancelled: () -> Bool, progress: (Int) -> Void) -> Outcome {
        var outcome = Outcome()
        // Encoding overlaps the next render; three lanes keep the GPU busy. Renders take
        // turns: each concurrent GPU render grew the retained footprint by about 250 MB.
        let renderLane = NSLock()
        Concurrent.ordered(chosen.count, width: width, stop: { cancelled() || outcome.failure != nil }) { i -> Result<Trial?, Error> in
            Result { try autoreleasepool { try export(chosen[i], into: folder, renderLane: renderLane, cancelled: cancelled) } }
        } deliver: { _, result in
            switch result {
            case .success(let trial?): outcome.exported.append(trial); progress(outcome.exported.count)
            case .success(nil): break
            case .failure(let error): if outcome.failure == nil { outcome.failure = error }
            }
        }
        return outcome
    }

    private static func export(_ trial: Trial, into folder: URL, renderLane: NSLock,
                               cancelled: () -> Bool) throws -> Trial? {
        if cancelled() { return nil }
        renderLane.lock()
        let rendered = Renderer.renderAlone(trial.art, longEdge: 2400)
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
