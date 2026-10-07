import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Material: String, CaseIterable {
    case image, stripes, dots, checker, rings, noise
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .image: return "photo"; case .stripes: return "line.3.horizontal"; case .dots: return "circle.grid.3x3.fill"; case .checker: return "square.grid.3x3.fill"; case .rings: return "circle.dotted"; case .noise: return "sparkles" }
    }
}
enum Blend: String, CaseIterable {
    case normal, multiply, screen, overlay, difference, softLight
    var label: String { self == .softLight ? "Soft light" : rawValue.capitalized }
    var filter: String {
        switch self { case .normal: return "CISourceOverCompositing"; case .multiply: return "CIMultiplyBlendMode"; case .screen: return "CIScreenBlendMode"; case .overlay: return "CIOverlayBlendMode"; case .difference: return "CIDifferenceBlendMode"; case .softLight: return "CISoftLightBlendMode" }
    }
}
struct Ink: Equatable {
    var r: Double; var g: Double; var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent
    }
}
struct Layer: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var material: Material
    var image: Data? = nil
    var sourcePath: String? = nil
    var visible = true
    var opacity = 1.0
    var blend = Blend.normal
    var scale = 1.0
    var rotation = 0.0
    var x = 0.0
    var y = 0.0
    var frequency = 12.0
    var tiles = 1 // Mirrored image repeats; 1 keeps the original photograph.
    var ink = Ink(0.17, 0.23, 0.38)
    var paper = Ink(0.95, 0.76, 0.42)
}
struct Warp: Equatable {
    var wave = 0.0
    var wavelength = 3.0
    var twist = 0.0
    var bulge = 0.0
    var pixel = 0.0
    var saturation = 1.0
    var contrast = 1.0
    var centerX = 0.5
    var centerY = 0.5
}
struct Artwork: Equatable {
    var layers: [Layer] = [] // bottom to top
    var warp = Warp()
    var aspect = "Square"
    var background = Ink(0.92, 0.9, 0.85)
    var ratio: Double { aspect == "Portrait" ? 0.8 : aspect == "Landscape" ? 1.4 : 1 }
}

final class Studio: ObservableObject {
    @Published var art = Artwork()
    @Published var selected: UUID?
    @Published var preview: NSImage?
    @Published var rendering = false
    @Published var error: String?
    @Published var status = "Ready to play"
    @Published var revision = 0
    @Published var comparing = false
    @Published var exporting = false
    @Published private(set) var sourceFolder: URL?
    @Published private(set) var sourceCount = 0
    @Published private(set) var sourceScanning = false
    @Published private(set) var gathering = false
    @Published private(set) var surpriseRevision = 0
    @Published private(set) var importing = false
    @Published private(set) var sourceMessage = "Choose a folder for Surprise me."
    @Published private(set) var trials: [Trial] = []
    @Published private(set) var trialsFolder: URL?
    @Published var favouriteTrials: Set<UUID> = []
    @Published private(set) var stage = SessionStage.material
    @Published private(set) var activeTrialID: UUID?
    @Published var batchAspect = "Square"
    @Published private(set) var refinement = Refinement()
    @Published private(set) var makingTrials = false
    @Published private(set) var trialProgress = 0
    @Published private(set) var trialMessage = ""
    @Published private(set) var exportingTrials = false
    @Published private(set) var trialExportProgress = 0
    @Published private(set) var trialExportTotal = 0
    private let trialsQueue = DispatchQueue(label: "Meld.trials", qos: .userInitiated)
    private var trialJob = CancellableJob()
    private var trialExportJob = CancellableJob()
    private let materialsQueue = DispatchQueue(label: "Meld.materials", qos: .userInitiated)
    private let materialLoader = MaterialLoader()
    private var scanToken = UUID()
    private var surpriseToken = UUID()
    private var lastMaterials: Set<URL> = []
    private var lastStyle: CompositionStyle?
    private var pendingImports = 0
    private let restoreSource: Bool
    private var history: [Artwork] = []
    private var future: [Artwork] = []
    private var lastKey = ""
    private var lastChange = Date.distantPast
    private var refinementHistory: [Refinement] = []
    private var refinementFuture: [Refinement] = []
    private var job: DispatchWorkItem?
    private let queue = DispatchQueue(label: "Meld.render", qos: .userInitiated)
    private var generation = 0
    let renderer = Renderer()
    var current: Layer? { art.layers.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(restoreSource: Bool = true, starter: Bool = true) {
        self.restoreSource = restoreSource
        if starter { loadStarter(record: false) }
        if restoreSource {
            UserDefaults.standard.removeObject(forKey: "source.recursive")
            var stale = false
            if let data = UserDefaults.standard.data(forKey: "source.bookmark"),
               let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                setSourceFolder(url, scan: false)
            } else if let path = UserDefaults.standard.string(forKey: "source.path") {
                setSourceFolder(URL(fileURLWithPath: path), scan: false)
            }
        }
    }
    var materialsBusy: Bool { gathering || sourceScanning || importing }
    func chooseSourceFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Use this folder"
        panel.message = "Choose photos, RAW files, or textures for your previews"
        panel.directoryURL = sourceFolder
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] result in
                if result == .OK, let url = panel.url { self?.setSourceFolder(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url { setSourceFolder(url) }
    }
    func setSourceFolder(_ url: URL, scan: Bool = true) {
        storeActiveTrial(); activeTrialID = nil; stage = .material
        cancelTrials()
        scanToken = UUID(); sourceScanning = false
        surpriseToken = UUID(); gathering = false; lastMaterials = []; lastStyle = nil
        sourceFolder = url; sourceCount = 0
        if restoreSource {
            UserDefaults.standard.set(url.path, forKey: "source.path")
            if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: "source.bookmark")
            }
        }
        if scan { refreshSource() }
        else { sourceMessage = "Subfolders and RAW files are included." }
    }
    func clearSourceFolder() {
        cancelTrials()
        scanToken = UUID(); surpriseToken = UUID(); sourceScanning = false; gathering = false
        sourceFolder = nil; sourceCount = 0; lastMaterials = []; sourceMessage = "Choose a folder for Surprise me."
        if restoreSource {
            UserDefaults.standard.removeObject(forKey: "source.path")
            UserDefaults.standard.removeObject(forKey: "source.bookmark")
        }
    }
    func refreshSource() {
        guard let folder = sourceFolder else { return }
        scanToken = UUID(); let token = scanToken
        sourceScanning = true; sourceMessage = "Looking for images…"
        materialsQueue.async { [weak self] in
            let result = Result { try MaterialLoader.scan(folder) }
            DispatchQueue.main.async {
                guard let self, self.scanToken == token else { return }
                self.sourceScanning = false
                switch result {
                case .success(let scan):
                    self.sourceCount = scan.urls.count
                    self.sourceMessage = scan.urls.isEmpty ? "No image files found." : "\(scan.urls.count) image files, including RAW"
                    if scan.unreadableFolders > 0 { self.sourceMessage += " · Some folders unavailable" }
                case .failure: self.sourceCount = 0; self.sourceMessage = "Folder unavailable. Choose it again."
                }
            }
        }
    }
    func change(_ key: String, _ body: (inout Artwork) -> Void) {
        let old = art
        body(&art)
        guard art != old else { return }
        if key != lastKey || Date().timeIntervalSince(lastChange) > 0.45 {
            history.append(old)
            refinementHistory.append(refinement)
            if history.count > 50 { history.removeFirst(); refinementHistory.removeFirst() }
        }
        lastKey = key; lastChange = Date(); future.removeAll(); refinementFuture.removeAll()
        revision += 1; schedule()
    }
    func updateLayer(_ key: String, _ body: (inout Layer) -> Void) {
        guard let id = selected else { return }
        change("\(id)-\(key)") { a in
            if let i = a.layers.firstIndex(where: { $0.id == id }) { body(&a.layers[i]) }
        }
    }
    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(art); refinementFuture.append(refinement)
        art = previous; refinement = refinementHistory.popLast() ?? Refinement(); finishHistory()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        history.append(art); refinementHistory.append(refinement)
        art = next; refinement = refinementFuture.popLast() ?? Refinement(); finishHistory()
    }
    private func finishHistory() {
        lastKey = ""; revision += 1
        if !art.layers.contains(where: { $0.id == selected }) { selected = art.layers.last?.id }
        schedule()
    }
    func addPattern(_ type: Material) {
        let l = Layer(name: type.label, material: type, opacity: 0.55, blend: .multiply)
        change("add-\(UUID())") { $0.layers.append(l) }; selected = l.id
    }
    func remove() {
        guard let id = selected else { return }
        change("delete-\(UUID())") { $0.layers.removeAll { $0.id == id } }
        selected = art.layers.last?.id
    }
    func duplicate() {
        guard var layer = current else { return }
        layer.id = UUID(); layer.name += " copy"
        change("duplicate-\(UUID())") { $0.layers.append(layer) }; selected = layer.id
    }
    // List offsets are top-to-bottom; the renderer stores layers bottom-to-top.
    func reorderLayers(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ art.layers.indices.contains($0) }),
              (0...art.layers.count).contains(destination) else { return }
        var displayed = Array(art.layers.reversed())
        displayed.move(fromOffsets: offsets, toOffset: destination)
        change("reorder-\(UUID())") { $0.layers = Array(displayed.reversed()) }
    }
    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !urls.contains(where: { $0.pathExtension.lowercased() == "meld" }) else {
            error = "Meld project files are no longer supported. Add images or textures instead."
            return
        }
        pendingImports += 1; importing = true; status = "Loading images…"
        materialsQueue.async { [weak self] in
            guard let self else { return }
            var layers: [Layer] = []; var failed: [String] = []
            for url in urls {
                autoreleasepool {
                    if let loaded = self.materialLoader.load(url) { layers.append(loaded.layer) }
                    else { failed.append(url.lastPathComponent) }
                }
            }
            DispatchQueue.main.async {
                self.pendingImports -= 1; self.importing = self.pendingImports > 0
                if !layers.isEmpty {
                    self.change("import-\(UUID())") { $0.layers.append(contentsOf: layers) }; self.selected = layers.last?.id
                    self.status = "Added \(layers.count) image\(layers.count == 1 ? "" : "s")"
                }
                if !failed.isEmpty {
                    self.error = "Couldn’t open: \(failed.prefix(3).joined(separator: ", ")). RAW support depends on the camera and macOS decoder; try JPEG or TIFF copies for unsupported files."
                }
            }
        }
    }
    func importPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        // Validate by decoding after selection; type metadata can be unavailable
        // for newly generated textures and files from cloud-backed folders.
        p.allowedContentTypes = []; p.allowsOtherFileTypes = true
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.message = "Add pictures or textures to your experiment"
        if let window = NSApp.keyWindow {
            p.beginSheetModal(for: window) { [weak self] response in
                if response == .OK { self?.importImages(p.urls) }
            }
        } else if p.runModal() == .OK { importImages(p.urls) }
    }
    private var previewLongEdge = 1000
    func setMagnifiedPreview(_ magnified: Bool) {
        let edge = magnified ? 2400 : 1000
        guard previewLongEdge != edge else { return }
        previewLongEdge = edge
        schedule()
    }
    func schedule() {
        job?.cancel(); generation += 1
        let token = generation
        let snapshot = comparing ? activeTrial?.original ?? art : art
        let raw = comparing && activeTrialID == nil; let edge = previewLongEdge
        rendering = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let image = self.renderer.render(snapshot, longEdge: edge, bypass: raw)
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.preview = image.map { NSImage(cgImage: $0, size: .zero) }
                self.rendering = false
                if image == nil { self.error = "The preview couldn’t render. Try undoing the last change." }
            }
        }
        job = work; queue.asyncAfter(deadline: .now() + 0.07, execute: work)
    }
    func loadStarter(record: Bool = true) {
        let base = Layer(name: "Colour study", material: .image, image: Renderer.starterPNG())
        let rings = Layer(name: "Rings", material: .rings, opacity: 0.35, blend: .softLight, rotation: -18, frequency: 13, ink: Ink(0.09,0.18,0.35), paper: Ink(0.95,0.69,0.3))
        var next = Artwork(); next.layers = [base, rings]; next.warp.wave = 0.13; next.warp.twist = 0.3
        if record { change("starter-\(UUID())") { $0 = next } } else { art = next; schedule() }
        selected = base.id; status = "A starting point. Make it yours."
    }
    func newCanvas() {
        change("new") { $0 = Artwork() }; selected = nil; status = "Drop in an image, or add a pattern"
    }
    func randomize() {
        guard !materialsBusy else { return }
        if let folder = sourceFolder { surpriseFromFolder(folder); return }
        change("shuffle-\(UUID())") { Self.shuffleEffects(&$0) }
        status = "Another possibility. Undo takes you back."
    }
    private static func shuffleEffects(_ a: inout Artwork) {
        a.warp = Warp()
        switch Int.random(in: 0...3) {
        case 0: a.warp.wave = Double.random(in: 0.17...0.4); a.warp.wavelength = Double.random(in: 1.4...4.5)
        case 1: a.warp.twist = [-1.0, 1.0].randomElement()! * Double.random(in: 1.2...2.7); a.warp.bulge = Double.random(in: -0.2...0.35)
        case 2: a.warp.pixel = Double.random(in: 0.35...0.9)
        default: a.warp.wave = Double.random(in: 0.02...0.08); a.warp.contrast = Double.random(in: 0.85...1.15)
        }
        a.warp.saturation = Double.random(in: 0.8...1.25)
        a.warp.centerX = Double.random(in: 0.25...0.75); a.warp.centerY = Double.random(in: 0.25...0.75)
        for i in a.layers.indices where a.layers[i].material != .image {
            a.layers[i].rotation = Double.random(in: -90...90)
            a.layers[i].frequency = Double.random(in: 5...28)
            a.layers[i].opacity = Double.random(in: 0.2...0.7)
        }
    }
    private func surpriseFromFolder(_ folder: URL) {
        gathering = true; surpriseToken = UUID()
        let token = surpriseToken; let startingRevision = revision; let previous = lastMaterials
        let style = CompositionStyle.allCases.filter { $0 != lastStyle }.randomElement()!
        let snapshot = art
        status = "Gathering material…"
        materialsQueue.async { [weak self] in
            guard let self else { return }
            do {
                let scan = try MaterialLoader.scan(folder)
                let shuffled = scan.urls.shuffled()
                // Prefer a fresh set when the library has enough choices.
                let candidates = shuffled.filter { !previous.contains($0) } + shuffled.filter { previous.contains($0) }
                let wanted = min(candidates.count, Int.random(in: 2...3))
                var loaded: [LoadedMaterial] = []; var used: Set<URL> = []; var failed = 0
                for url in candidates.prefix(32) {
                    if loaded.count >= wanted { break }
                    autoreleasepool {
                        if let material = self.materialLoader.load(url) { loaded.append(material); used.insert(url) }
                        else { failed += 1 }
                    }
                }
                let composition = TrialGenerator.compose(loaded.map { PreparedMaterial($0.layer) },
                    style: style, aspect: snapshot.aspect, seed: UInt64.random(in: 0...UInt64.max))
                DispatchQueue.main.async {
                    guard self.surpriseToken == token else { return }
                    self.gathering = false; self.sourceCount = scan.urls.count
                    self.sourceMessage = scan.urls.isEmpty ? "No image files found." : "\(scan.urls.count) image files, including RAW"
                    guard self.revision == startingRevision else {
                        self.status = "Canvas changed while gathering. Try Surprise me again."; return
                    }
                    guard !loaded.isEmpty else {
                        self.status = "Your canvas is unchanged."
                        self.error = scan.urls.isEmpty ? "No image files found in this folder or its subfolders. Choose another folder." : "Couldn’t open any of the sampled files. Unsupported RAWs may need JPEG or TIFF copies."
                        return
                    }
                    self.lastMaterials = used
                    self.lastStyle = style
                    self.change("surprise-\(UUID())") { $0 = composition }
                    self.selected = composition.layers.first(where: { $0.material == .image })?.id
                    // Comparing should not accidentally conceal the new effects.
                    if self.comparing { self.comparing = false; self.schedule() }
                    self.status = "\(style.rawValue) · \(loaded.count) source image\(loaded.count == 1 ? "" : "s"). Undo takes you back."
                    if failed > 0 { self.status += " Skipped \(failed) unreadable." }
                    self.surpriseRevision += 1
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.surpriseToken == token else { return }
                    self.gathering = false; self.sourceMessage = "Folder unavailable. Choose it again."
                    self.error = "Couldn’t read your source folder. Choose it again if it moved, or reconnect its drive."
                }
            }
        }
    }
    func preset(_ name: String) {
        change("preset-\(name)") { a in
            a.warp = Warp()
            switch name {
            case "Flow": a.warp.wave = 0.32; a.warp.wavelength = 3.2; a.warp.twist = 0.7
            case "Vortex": a.warp.twist = 2.4; a.warp.bulge = 0.35
            case "Blocks": a.warp.pixel = 0.27; a.warp.saturation = 1.3; a.warp.contrast = 1.1
            default: break
            }
        }
    }
    func showTrials() {
        storeActiveTrial(); activeTrialID = nil
        stage = trials.isEmpty && !makingTrials ? .material : .previews
    }
    func chooseMaterial() {
        cancelTrials()
        storeActiveTrial(); activeTrialID = nil; stage = .material
    }
    func makeTrials(count: Int = 36) {
        guard let folder = sourceFolder, !materialsBusy, !makingTrials, !exportingTrials else { return }
        storeActiveTrial(); activeTrialID = nil; stage = .previews
        // The interface offers one useful batch size. A bound also protects programmatic calls.
        let count = min(48, max(1, count))
        trialJob.cancel(); let task = CancellableJob(); trialJob = task
        makingTrials = true; trialProgress = 0; trialMessage = "Gathering images…"
        let aspect = batchAspect
        let seed = UInt64.random(in: 0...UInt64.max)
        trialsQueue.async { [weak self] in
            guard let self else { return }
            let loader = MaterialLoader(), renderer = Renderer()
            do {
                let scan = try MaterialLoader.scan(folder, cancelled: { task.cancelled })
                let wanted = min(12, scan.urls.count)
                var pool: [PreparedMaterial] = []; var skipped = 0
                for url in scan.urls.shuffled().prefix(64) {
                    if task.cancelled { return }
                    if pool.count >= wanted { break }
                    autoreleasepool {
                        if let loaded = loader.load(url, maximum: 2400) { pool.append(PreparedMaterial(loaded.layer)) }
                        else { skipped += 1 }
                    }
                    let loadedCount = pool.count
                    DispatchQueue.main.async {
                        guard self.trialJob === task, !task.cancelled else { return }
                        self.trialMessage = "Gathering images · \(loadedCount) ready"
                    }
                }
                guard !task.cancelled else { return }
                guard !pool.isEmpty else {
                    DispatchQueue.main.async {
                        guard self.trialJob === task, !task.cancelled else { return }
                        self.makingTrials = false
                        self.sourceCount = scan.urls.count
                        self.trialMessage = "No usable images found."
                        self.error = scan.urls.isEmpty ? "No images found in this folder or its subfolders. Choose another folder." : "Couldn’t open the sampled images. Unsupported RAW files may need JPEG or TIFF copies."
                    }
                    return
                }
                let styles = TrialGenerator.styles(count: count, seed: seed)
                let loadedCount = pool.count
                var produced = 0
                for (i, style) in styles.enumerated() {
                    if task.cancelled { return }
                    let trial: Trial? = autoreleasepool {
                        let art = TrialGenerator.compose(pool, style: style, aspect: aspect, seed: seed &+ UInt64(i+1))
                        guard let image = renderer.render(art, longEdge: 480) else { return nil }
                        return Trial(number: i+1, style: style, art: art, thumbnail: image)
                    }
                    guard let trial else { continue }
                    produced += 1; let first = produced == 1
                    DispatchQueue.main.async {
                        guard self.trialJob === task, !task.cancelled else { return }
                        if first { self.trials = []; self.favouriteTrials = []; self.trialsFolder = folder }
                        self.trials.append(trial); self.trialProgress = self.trials.count
                        self.trialMessage = "Making previews · \(self.trials.count) of \(count)"
                    }
                }
                DispatchQueue.main.async {
                    guard self.trialJob === task, !task.cancelled else { return }
                    self.makingTrials = false; self.sourceCount = scan.urls.count
                    self.sourceMessage = "\(scan.urls.count) image files, including RAW"
                    self.trialMessage = "\(produced) previews · \(loadedCount) source images"
                    if skipped > 0 { self.trialMessage += " · \(skipped) unreadable skipped" }
                    if scan.unreadableFolders > 0 { self.trialMessage += " · Some folders unavailable" }
                    if produced == 0 { self.error = "The trials couldn’t render. Your previous trials and canvas are unchanged." }
                    self.status = self.trialMessage
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.trialJob === task, !task.cancelled else { return }
                    self.makingTrials = false; self.trialMessage = "Folder unavailable."
                    self.error = "Couldn’t read the source folder. Choose it again or reconnect its drive."
                }
            }
        }
    }
    func cancelTrials() {
        guard makingTrials else { return }
        trialJob.cancel(); makingTrials = false
        trialMessage = trialProgress > 0 ? "Stopped at \(trials.count) previews" : "Generation stopped"
    }
    func toggleFavourite(_ id: UUID) {
        if favouriteTrials.contains(id) { favouriteTrials.remove(id) }
        else if trials.contains(where: { $0.id == id }) { favouriteTrials.insert(id) }
    }
    func openTrial(_ id: UUID) {
        guard !makingTrials else { return }
        if activeTrialID == id { return }
        storeActiveTrial()
        guard let trial = trials.first(where: { $0.id == id }) else { return }
        art = trial.art; refinement = trial.refinement
        history = []; future = []; refinementHistory = []; refinementFuture = []; lastKey = ""
        activeTrialID = id; stage = .refine; revision += 1
        selected = trial.art.layers.first(where: { $0.material == .image })?.id
        comparing = false; schedule()
        surpriseRevision += 1; status = trial.title
    }
    var activeTrial: Trial? { trials.first { $0.id == activeTrialID } }
    func setRefinement(_ key: String, value: Double) {
        guard let original = activeTrial?.original, value.isFinite, ["distortion", "pattern"].contains(key) else { return }
        change(key) { artwork in
            if key == "distortion" {
                artwork.warp.wave = original.warp.wave * value
                artwork.warp.twist = original.warp.twist * value
                artwork.warp.bulge = min(0.9, max(-0.9, original.warp.bulge * value))
                artwork.warp.pixel = min(1, original.warp.pixel * value)
            } else {
                for i in artwork.layers.indices where artwork.layers[i].material != .image {
                    if let base = original.layers.first(where: { $0.id == artwork.layers[i].id }) {
                        artwork.layers[i].opacity = min(1, base.opacity * value)
                    }
                }
            }
        }
        if key == "distortion" { refinement.distortion = value } else { refinement.pattern = value }
    }
    func resetActiveTrial() {
        guard let trial = activeTrial else { return }
        change("reset-preview-\(UUID())") { $0 = trial.original }
        refinement = Refinement()
    }
    func storeActiveTrial() {
        guard let id = activeTrialID, let i = trials.firstIndex(where: { $0.id == id }) else { return }
        let changed = trials[i].art != art
        trials[i].art = art; trials[i].refinement = refinement
        guard changed else { return }
        let snapshot = art
        queue.async { [weak self] in
            guard let self else { return }
            let image = autoreleasepool { self.renderer.render(snapshot, longEdge: 480) }
            DispatchQueue.main.async {
                guard let image, let index = self.trials.firstIndex(where: { $0.id == id }), self.trials[index].art == snapshot else { return }
                self.trials[index].thumbnail = image
            }
        }
    }
    func exportTrials() {
        storeActiveTrial()
        let chosen = trials.filter { favouriteTrials.contains($0.id) }
        guard !chosen.isEmpty, !exportingTrials, !makingTrials else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Export picks"
        panel.message = "Export \(chosen.count) PNGs and a contact sheet into a new folder"
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let folder = panel.url { self?.exportTrials(chosen, to: folder) }
            }
        } else if panel.runModal() == .OK, let folder = panel.url { exportTrials(chosen, to: folder) }
    }
    func exportTrials(_ chosen: [Trial], to parent: URL) {
        guard !chosen.isEmpty, !exportingTrials, !makingTrials else { return }
        let task = CancellableJob(); trialExportJob = task
        exportingTrials = true; trialExportProgress = 0; trialExportTotal = chosen.count
        trialsQueue.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let folder = parent.appendingPathComponent("Meld trials \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6))", isDirectory: true)
            let renderer = Renderer()
            var completed = 0
            var exported: [Trial] = []
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                for trial in chosen {
                    if task.cancelled { break }
                    try autoreleasepool {
                        guard let cg = renderer.render(trial.art, longEdge: 2400),
                              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                        if task.cancelled { return }
                        try png.write(to: folder.appendingPathComponent("\(trial.title).png"), options: .withoutOverwriting)
                        var copy = trial
                        let scale = min(1, 480 / Double(max(cg.width, cg.height)))
                        if let ctx = Renderer.canvas(w: max(1, Int(Double(cg.width) * scale)), h: max(1, Int(Double(cg.height) * scale))) {
                            ctx.interpolationQuality = .high
                            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
                            if let thumbnail = ctx.makeImage() { copy.thumbnail = thumbnail }
                        }
                        exported.append(copy)
                        completed += 1
                    }
                    let progress = completed
                    DispatchQueue.main.async { self.trialExportProgress = progress }
                }
                if completed > 0, let contact = TrialGenerator.contactSheet(exported) {
                    try contact.write(to: folder.appendingPathComponent("Contact sheet.png"), options: .withoutOverwriting)
                }
                DispatchQueue.main.async {
                    self.exportingTrials = false
                    self.status = "\(task.cancelled ? "Stopped export; saved" : "Exported") \(completed) trials in \(folder.lastPathComponent)"
                    self.trialMessage = self.status
                }
            } catch {
                DispatchQueue.main.async {
                    self.exportingTrials = false
                    self.error = "Couldn’t finish exporting trials: \(error.localizedDescription). \(completed) PNGs were saved in \(folder.lastPathComponent)."
                }
            }
        }
    }
    func cancelTrialExport() { trialExportJob.cancel() }
    func export() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "Meld.png"
        p.message = "Export your artwork as a PNG (2400 pixels on the longest side)"
        guard p.runModal() == .OK, let url = p.url else { return }
        export(to: url)
    }
    func export(to url: URL) {
        guard !exporting else { return }
        exporting = true; let snapshot = art
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let cg = self.renderer.render(snapshot, longEdge: 2400), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { self.exporting = false; self.status = "Exported \(url.lastPathComponent)" }
            } catch { DispatchQueue.main.async { self.exporting = false; self.error = "Couldn’t export: \(error.localizedDescription)" } }
        }
    }
}
