import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

enum Material: String, CaseIterable {
    case image, stripes, dots, checker, rings, noise
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .image: return "photo"; case .stripes: return "line.3.horizontal"; case .dots: return "circle.grid.3x3.fill"; case .checker: return "square.grid.3x3.fill"; case .rings: return "circle.dotted"; case .noise: return "sparkles" }
    }
}
enum Blend: String, CaseIterable {
    case normal, multiply, screen, overlay, softLight, hardLight, colorDodge, colorBurn, difference, exclusion, luminosity, color
    var label: String {
        switch self {
        case .softLight: return "Soft light"; case .hardLight: return "Hard light"
        case .colorDodge: return "Colour dodge"; case .colorBurn: return "Colour burn"; case .color: return "Colour"
        default: return rawValue.capitalized
        }
    }
    var filter: String {
        switch self {
        case .normal: return "CISourceOverCompositing"; case .multiply: return "CIMultiplyBlendMode"; case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"; case .difference: return "CIDifferenceBlendMode"; case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"; case .colorDodge: return "CIColorDodgeBlendMode"; case .colorBurn: return "CIColorBurnBlendMode"
        case .exclusion: return "CIExclusionBlendMode"; case .luminosity: return "CILuminosityBlendMode"; case .color: return "CIColorBlendMode"
        }
    }
}
/// Where an image layer shows: everywhere, where the layers below are bright or dark, or along a soft fade.
enum MaskKind: String, CaseIterable {
    case none, bright, dark, linear, radial
    var label: String {
        switch self { case .none: return "None"; case .bright: return "Bright areas"; case .dark: return "Dark areas"; case .linear: return "Linear fade"; case .radial: return "Radial fade" }
    }
}
enum Symmetry: String, CaseIterable {
    case none, vertical, horizontal, both
    var label: String {
        switch self { case .none: return "Off"; case .vertical: return "Left · right"; case .horizontal: return "Top · bottom"; case .both: return "Four ways" }
    }
}
enum ColourTreatment: String, CaseIterable {
    case none, gradientMap, paletteSwap, posterize, hue
    var label: String {
        switch self { case .none: return "None"; case .gradientMap: return "Gradient map"; case .paletteSwap: return "Palette swap"; case .posterize: return "Posterize"; case .hue: return "Hue shift" }
    }
}
enum BlurKind: String, CaseIterable {
    case none, motion, zoom
    var label: String { self == .none ? "Off" : rawValue.capitalized }
}
/// Whole-composite stages that simplify a preview into a painting idea. Every default means off.
struct Effects: Equatable {
    var symmetry = Symmetry.none
    /// Mirror axes as fractions of the width and of the height from the top.
    var splitX = 0.5
    var splitY = 0.5
    var colour = ColourTreatment.none
    /// How much of the colour treatment replaces the original colours; hue shift scales its angle.
    var colourMix = 0.0
    /// Gradient map and palette swap colours, dark to light.
    var colours: [Ink] = []
    var levels = 6
    var hue = 0.0
    var blur = BlurKind.none
    /// Blur length as a fraction of the long edge.
    var blurAmount = 0.0
    var blurAngle = 0.0
    var blurMix = 0.5
    /// Fine surface texture: grey noise at this opacity.
    var grain = 0.0
    var grainBlend = Blend.softLight
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
    var image: SourceImage? = nil
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
    /// Extra scale along `stretchAngle` (degrees, canvas axes) around the layer centre; 1 is off.
    var stretch = 1.0
    var stretchAngle = 0.0
    var mask = MaskKind.none
    /// Luminance threshold (bright/dark), edge offset from the centre in canvas heights (linear),
    /// or radius as a fraction of the long edge (radial).
    var maskPosition = 0.5
    var maskSoftness = 0.2
    var maskAngle = 0.0
    var maskX = 0.5
    var maskY = 0.5
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
    var effects = Effects()
    var aspect = "Square"
    var background = Ink(0.92, 0.9, 0.85)
    var ratio: Double { aspect == "Portrait" ? 0.8 : aspect == "Landscape" ? 1.4 : 1 }
}

/// The session model. Observation tracks each property separately, so a view re-renders only
/// when something it reads changes; bookkeeping no view reads is ignored.
@Observable final class Studio {
    var art = Artwork()
    var selected: UUID?
    var preview: NSImage?
    var rendering = false
    var error: String?
    var status = "Ready to play"
    var revision = 0
    var comparing = false
    var exporting = false
    private(set) var sourceFolder: URL?
    private(set) var sourceCount = 0
    private(set) var sourceScanning = false
    private(set) var gathering = false
    private(set) var surpriseRevision = 0
    private(set) var importing = false
    private(set) var sourceMessage = "Choose a folder for Surprise me."
    private(set) var trials: [Trial] = []
    private(set) var trialsFolder: URL?
    var favouriteTrials: Set<UUID> = []
    private(set) var stage = SessionStage.material
    private(set) var activeTrialID: UUID?
    var batchAspect = "Square"
    private(set) var refinement = Refinement()
    private(set) var makingTrials = false
    private(set) var trialProgress = 0
    private(set) var trialMessage = ""
    private(set) var exportingTrials = false
    private(set) var trialExportProgress = 0
    private(set) var trialExportTotal = 0
    /// Grid rows, newest first. A new set keeps earlier picks in their original rows.
    private(set) var groups: [TrialGroup] = []
    var gridSelection: UUID?
    var picksOnly = false { didSet { keepSelectionVisible() } }
    /// Main colours of the refined preview as displayed (before any value study).
    private(set) var palette: [Ink] = []
    private(set) var study = Study.colour
    private(set) var copying = false
    /// Grid thumbnail width in points; preview thumbnails are 480 pixels, sharp up to 240 points on Retina.
    static let thumbnailSizes: [Double] = [130, 170, 210, 250]
    private(set) var thumbnailSize = 170.0
    func zoomThumbnails(_ step: Int) {
        let sizes = Self.thumbnailSizes
        let index = sizes.firstIndex(of: thumbnailSize) ?? 1
        thumbnailSize = sizes[min(sizes.count - 1, max(0, index + step))]
        if restoreSource { UserDefaults.standard.set(thumbnailSize, forKey: "grid.thumbnailSize") }
    }
    /// Tests use a private pasteboard so they never replace the user's clipboard.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    /// Seeds new sets and variations. The benchmark fixes it so its runs repeat the same work.
    @ObservationIgnored var nextSeed: () -> UInt64 = { UInt64.random(in: 0...UInt64.max) }
    @ObservationIgnored private var nextTrialNumber = 1
    @ObservationIgnored private var nextGroupID = 1
    @ObservationIgnored private var setCount = 0
    private let trialsQueue = DispatchQueue(label: "Meld.trials", qos: .userInitiated)
    @ObservationIgnored private var trialJob = CancellableJob()
    @ObservationIgnored private var trialExportJob = CancellableJob()
    private let materialsQueue = DispatchQueue(label: "Meld.materials", qos: .userInitiated)
    private let materialLoader = MaterialLoader()
    @ObservationIgnored private var scanToken = UUID()
    @ObservationIgnored private var scanJob = CancellableJob()
    @ObservationIgnored private var surpriseToken = UUID()
    @ObservationIgnored private var surpriseJob = CancellableJob()
    @ObservationIgnored private var lastMaterials: Set<URL> = []
    @ObservationIgnored private var lastStyle: CompositionStyle?
    @ObservationIgnored private var pendingImports = 0
    private let restoreSource: Bool
    private var history: [Artwork] = []
    private var future: [Artwork] = []
    @ObservationIgnored private var lastKey = ""
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var refinementHistory: [Refinement] = []
    @ObservationIgnored private var refinementFuture: [Refinement] = []
    private struct PreviewScope: Equatable {
        let visit: Int
        let trial: UUID?
        let comparing: Bool
        let study: Study
        let layers: [UUID]
        let aspect: String
        let edge: Int
    }
    private struct PreviewRequest {
        let art: Artwork
        let scope: PreviewScope
        let token: Int
        let interactive: Bool
    }
    @ObservationIgnored private var pendingPreview: PreviewRequest?
    @ObservationIgnored private var previewScope: PreviewScope?
    @ObservationIgnored private var previewWake: DispatchWorkItem?
    @ObservationIgnored private var previewWakeDate: Date?
    @ObservationIgnored private var previewInFlight = false
    @ObservationIgnored private var lastPreviewStart = Date.distantPast
    @ObservationIgnored private var lastPreviewChange = Date.distantPast
    private let queue = DispatchQueue(label: "Meld.render", qos: .userInitiated)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previewVisit = 0
    let renderer = Renderer()
    private let batchRenderer = Renderer()
    /// Exports, copies and drags render full size on a context of their own (`Renderer.renderAlone`).
    private let exportQueue = DispatchQueue(label: "Meld.export", qos: .userInitiated)
    var current: Layer? { art.layers.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(restoreSource: Bool = true, starter: Bool = true) {
        self.restoreSource = restoreSource
        if starter { loadStarter(record: false) }
        if restoreSource {
            let size = UserDefaults.standard.double(forKey: "grid.thumbnailSize")
            if Self.thumbnailSizes.contains(size) { thumbnailSize = size }
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
        storeActiveTrial(); cancelPreview(); activeTrialID = nil; stage = .material
        cancelTrials()
        scanJob.cancel()
        scanToken = UUID(); sourceScanning = false
        surpriseJob.cancel()
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
        scanJob.cancel(); surpriseJob.cancel()
        scanToken = UUID(); surpriseToken = UUID(); sourceScanning = false; gathering = false
        sourceFolder = nil; sourceCount = 0; lastMaterials = []; sourceMessage = "Choose a folder for Surprise me."
        if restoreSource {
            UserDefaults.standard.removeObject(forKey: "source.path")
            UserDefaults.standard.removeObject(forKey: "source.bookmark")
        }
    }
    func refreshSource() {
        guard let folder = sourceFolder else { return }
        scanJob.cancel(); let task = CancellableJob(); scanJob = task
        scanToken = UUID(); let token = scanToken
        sourceScanning = true; sourceMessage = "Looking for images…"
        materialsQueue.async { [weak self] in
            let result = Result { try MaterialLoader.scan(folder, cancelled: { task.cancelled }) }
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
        lastKey = key; lastChange = Date(); refinementFuture.removeAll()
        if !future.isEmpty { future.removeAll() }
        revision += 1; schedule(interactive: true)
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
    @ObservationIgnored private var previewLongEdge = 1000
    func setMagnifiedPreview(_ magnified: Bool) {
        let edge = magnified ? 2400 : 1000
        guard previewLongEdge != edge else { return }
        previewLongEdge = edge
        schedule()
    }
    // Main-thread scheduler: one render in flight and one replaceable latest request.
    // Completed drafts of this same canvas can appear during a gesture; a new trial,
    // comparison, shape, or zoom scope rejects the old canvas's completion entirely.
    func schedule(interactive: Bool = false) {
        generation += 1
        let snapshot = comparing ? activeTrial?.original ?? art : art
        let scope = PreviewScope(visit: previewVisit, trial: activeTrialID, comparing: comparing, study: study,
                                 layers: snapshot.layers.map(\.id), aspect: snapshot.aspect, edge: previewLongEdge)
        previewScope = scope
        lastPreviewChange = Date()
        pendingPreview = PreviewRequest(art: snapshot, scope: scope, token: generation, interactive: interactive)
        if !rendering { rendering = true }
        wakePreview()
    }
    private func wakePreview(after delay: TimeInterval = 0) {
        guard !previewInFlight, pendingPreview != nil else { return }
        // Events may advance a final-quality deadline, but never postpone a draft.
        let wait = max(0, max(delay, 0.05 - Date().timeIntervalSince(lastPreviewStart)))
        let due = Date().addingTimeInterval(wait)
        if let scheduled = previewWakeDate, scheduled <= due { return }
        previewWake?.cancel()
        previewWakeDate = due
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewWake = nil; self.previewWakeDate = nil
            self.startPreview()
        }
        previewWake = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait), execute: work)
    }
    private func startPreview() {
        guard !previewInFlight, let request = pendingPreview else { return }
        pendingPreview = nil; previewInFlight = true; lastPreviewStart = Date()
        let draft = request.interactive && Date().timeIntervalSince(lastPreviewChange) < 0.12
        let edge = draft ? min(640, request.scope.edge) : request.scope.edge
        queue.async { [weak self] in
            guard let self else { return }
            let (image, palette): (CGImage?, [Ink]?) = autoreleasepool {
                let rendered = self.renderer.render(request.art, longEdge: edge,
                                                    bypass: request.scope.comparing && request.scope.trial == nil)
                let palette = draft ? nil : rendered.map { SourcePalette.colours(of: $0) }
                return (rendered.flatMap { request.scope.study.apply($0, context: self.renderer.context) }, palette)
            }
            DispatchQueue.main.async {
                self.previewInFlight = false
                if self.previewScope == request.scope {
                    self.preview = image.map { NSImage(cgImage: $0, size: .zero) }
                    if let palette { self.palette = palette }
                    if image == nil { self.error = "The preview couldn’t render. Try undoing the last change." }
                    if draft && self.generation == request.token {
                        self.pendingPreview = PreviewRequest(art: request.art, scope: request.scope,
                                                             token: request.token, interactive: false)
                    }
                }
                if self.pendingPreview != nil {
                    let delay = self.pendingPreview?.interactive == false && draft
                        ? max(0, 0.12 - Date().timeIntervalSince(self.lastPreviewChange)) : 0
                    self.wakePreview(after: delay)
                } else { self.rendering = false }
            }
        }
    }
    private func cancelPreview() {
        generation += 1; previewVisit += 1; previewScope = nil; pendingPreview = nil
        previewWake?.cancel(); previewWake = nil; previewWakeDate = nil; rendering = false
    }
    func loadStarter(record: Bool = true) {
        let base = Layer(name: "Colour study", material: .image, image: Renderer.starterPNG().flatMap { SourceImage(data: $0) })
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
        surpriseJob.cancel(); let task = CancellableJob(); surpriseJob = task
        gathering = true; surpriseToken = UUID()
        let token = surpriseToken; let startingRevision = revision; let previous = lastMaterials
        let style = CompositionStyle.allCases.filter { $0 != lastStyle }.randomElement()!
        let snapshot = art
        status = "Gathering material…"
        materialsQueue.async { [weak self] in
            guard let self else { return }
            do {
                let scan = try MaterialLoader.scan(folder, cancelled: { task.cancelled })
                let shuffled = scan.urls.shuffled()
                // Prefer a fresh set when the library has enough choices.
                let candidates = shuffled.filter { !previous.contains($0) } + shuffled.filter { previous.contains($0) }
                let wanted = min(candidates.count, Int.random(in: 2...3))
                var loaded: [LoadedMaterial] = []; var used: Set<URL> = []; var failed = 0
                for url in candidates.prefix(32) {
                    if task.cancelled { return }
                    if loaded.count >= wanted { break }
                    autoreleasepool {
                        if let material = self.materialLoader.load(url, cancelled: { task.cancelled }) { loaded.append(material); used.insert(url) }
                        else { failed += 1 }
                    }
                }
                guard !task.cancelled else { return }
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
        if let id = activeTrialID { gridSelection = id }
        storeActiveTrial(); cancelPreview(); activeTrialID = nil
        stage = trials.isEmpty && !makingTrials ? .material : .previews
    }
    func chooseMaterial() {
        cancelTrials()
        gridSelection = nil
        storeActiveTrial(); cancelPreview(); activeTrialID = nil; stage = .material
    }
    func makeTrials(count: Int = 36) {
        guard let folder = sourceFolder, !materialsBusy, !makingTrials, !exportingTrials else { return }
        storeActiveTrial(); cancelPreview(); activeTrialID = nil; stage = .previews
        // The interface offers one useful batch size. A bound also protects programmatic calls.
        let count = min(48, max(1, count))
        trialJob.cancel(); let task = CancellableJob(); trialJob = task
        makingTrials = true; trialProgress = 0; trialMessage = "Gathering images…"
        let aspect = batchAspect
        let seed = nextSeed()
        let group = TrialGroup(id: nextGroupID, title: "Set \(setCount + 1) · \(folder.lastPathComponent) · \(aspect)")
        nextGroupID += 1
        trialsQueue.async { [weak self] in
            guard let self else { return }
            let renderer = self.batchRenderer
            defer { renderer.context.clearCaches() }
            do {
                let scan = try MaterialLoader.scan(folder, cancelled: { task.cancelled })
                // Start with enough material for a recipe, then broaden each group of six.
                func poolSize(_ index: Int) -> Int { 3 + (index / 6) * 2 }
                let wanted = min(12, scan.urls.count, poolSize(count - 1))
                var sampling = RecipeRandom(seed: seed ^ 0x3c6ef372fe94f82b)
                let candidates = Array(scan.urls.shuffled(using: &sampling).prefix(64))
                // Decoding runs ahead on a few threads; the pool keeps sampled order.
                var started = false
                let gatherer = MaterialGatherer(candidates, wanted: wanted, workers: 3, loader: MaterialLoader(),
                                                cancelled: { task.cancelled }) { loadedCount in
                    DispatchQueue.main.async {
                        guard self.trialJob === task, !task.cancelled, !started else { return }
                        self.trialMessage = "Gathering images · \(loadedCount) ready"
                    }
                }
                let initial = gatherer.pool(atLeast: poolSize(0))
                guard !task.cancelled else { return }
                guard !initial.isEmpty else {
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
                let plans = TrialGenerator.plans(count: count, seed: seed)
                var produced = 0
                // Previews render concurrently on the shared context and arrive in number order.
                Concurrent.ordered(styles.count, width: 3, stop: { task.cancelled }) { i -> Trial? in
                    let pool = gatherer.pool(atLeast: poolSize(i))
                    if task.cancelled { return nil }
                    return autoreleasepool {
                        let art = TrialGenerator.compose(pool, style: styles[i], aspect: aspect, seed: seed &+ UInt64(i+1), plan: plans[i])
                        guard let image = renderer.render(art, longEdge: 480) else { return nil }
                        return Trial(number: i+1, style: styles[i], art: art, thumbnail: image)
                    }
                } deliver: { _, trial in
                    guard let trial, !task.cancelled else { return }
                    produced += 1; let first = produced == 1
                    DispatchQueue.main.async {
                        guard self.trialJob === task, !task.cancelled else { return }
                        if first {
                            // Replace the previous set, keeping its picks in their own rows.
                            self.keepOnlyPicks()
                            self.groups.insert(group, at: 0); self.setCount += 1
                            self.trialsFolder = folder; self.trialProgress = 0; started = true
                        }
                        self.append(trial, to: group)
                        self.trialMessage = "Making previews · \(self.trialProgress) of \(count)"
                    }
                }
                if task.cancelled { return }
                let pool = gatherer.pool(atLeast: poolSize(count - 1)), skipped = gatherer.skipped
                let loadedCount = pool.count
                DispatchQueue.main.async {
                    guard self.trialJob === task, !task.cancelled else { return }
                    self.makingTrials = false; self.sourceCount = scan.urls.count
                    self.sourceMessage = "\(scan.urls.count) image files, including RAW"
                    self.trialMessage = "\(produced) previews · \(loadedCount) source images"
                    if skipped > 0 { self.trialMessage += " · \(skipped) unreadable skipped" }
                    if scan.unreadableFolders > 0 { self.trialMessage += " · Some folders unavailable" }
                    if produced == 0 { self.error = "The previews couldn’t render. Your previous previews are unchanged." }
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
        trialMessage = trialProgress > 0 ? "Stopped at \(trialProgress) previews" : "Generation stopped"
    }
    private func keepOnlyPicks() {
        trials.removeAll { !favouriteTrials.contains($0.id) }
        groups.removeAll { group in !trials.contains { $0.group == group.id } }
        if let id = gridSelection, !trials.contains(where: { $0.id == id }) { gridSelection = nil }
    }
    private func append(_ trial: Trial, to group: TrialGroup) {
        var trial = trial
        trial.number = nextTrialNumber; trial.group = group.id; nextTrialNumber += 1
        trials.append(trial); trialProgress += 1
    }
    /// Grid order: newest row first, then generation order within a row.
    var orderedTrials: [Trial] {
        groups.flatMap { group in trials.filter { $0.group == group.id } }
    }
    var visibleTrials: [Trial] {
        picksOnly ? orderedTrials.filter { favouriteTrials.contains($0.id) } : orderedTrials
    }
    /// Moves the grid selection through visible previews; arrows use the row width.
    func moveSelection(by offset: Int) {
        let visible = visibleTrials
        guard !visible.isEmpty else { return }
        guard let id = gridSelection, let index = visible.firstIndex(where: { $0.id == id }) else {
            gridSelection = (offset < 0 ? visible.last : visible.first)?.id; return
        }
        gridSelection = visible[min(visible.count - 1, max(0, index + offset))].id
    }
    /// Moves the selection up or down a grid row, keeping its column where possible.
    func moveSelectionVertically(_ step: Int, columns: Int) {
        let columns = max(1, columns)
        var rows: [[UUID]] = []
        for group in groups {
            let ids = visibleTrials.filter { $0.group == group.id }.map(\.id)
            rows += stride(from: 0, to: ids.count, by: columns).map { Array(ids[$0..<min(ids.count, $0 + columns)]) }
        }
        guard !rows.isEmpty else { return }
        guard let id = gridSelection, let row = rows.firstIndex(where: { $0.contains(id) }),
              let column = rows[row].firstIndex(of: id) else { gridSelection = rows[0].first; return }
        let target = rows[min(rows.count - 1, max(0, row + step))]
        gridSelection = target[min(column, target.count - 1)]
    }
    func setPick(_ id: UUID, _ picked: Bool) {
        if picked != favouriteTrials.contains(id) { toggleFavourite(id) }
    }
    /// Opens the neighbouring visible preview from refinement.
    func openAdjacentTrial(_ step: Int) {
        if let id = adjacentTrial(step) { openTrial(id) }
    }
    var canOpenPrevious: Bool { adjacentTrial(-1) != nil }
    var canOpenNext: Bool { adjacentTrial(1) != nil }
    /// The next visible preview in grid order. The open preview itself may be hidden
    /// (for example after removing its pick while Picks is shown).
    private func adjacentTrial(_ step: Int) -> UUID? {
        guard let id = activeTrialID, !makingTrials else { return nil }
        let ordered = orderedTrials
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let visible = Set(visibleTrials.map(\.id))
        let candidates = step > 0 ? Array(ordered[(index + 1)...]) : Array(ordered[..<index].reversed())
        return candidates.first { visible.contains($0.id) }?.id
    }
    func setStudy(_ value: Study) {
        guard study != value else { return }
        study = value
        if stage == .refine { schedule() }
    }

    /// Twelve close relatives of one preview, added as a new row without decoding anything.
    var canMakeVariations: Bool { commandTarget != nil && !materialsBusy && !makingTrials && !exportingTrials }
    func makeVariations(of id: UUID, count: Int = 12) {
        guard !materialsBusy, !makingTrials, !exportingTrials else { return }
        storeActiveTrial()
        guard let base = trials.first(where: { $0.id == id }) else { return }
        cancelPreview(); activeTrialID = nil; stage = .previews; picksOnly = false
        let count = min(48, max(1, count))
        trialJob.cancel(); let task = CancellableJob(); trialJob = task
        makingTrials = true; trialProgress = 0; trialMessage = "Making variations of \(base.title)…"
        let group = TrialGroup(id: nextGroupID, title: "Variations of \(base.title)")
        nextGroupID += 1
        // The session's decoded images are the material pool; nothing is read from disk.
        var seen = Set<ObjectIdentifier>(), layers: [Layer] = []
        for trial in trials { for layer in trial.art.layers where layer.material == .image {
            if let image = layer.image, seen.insert(ObjectIdentifier(image)).inserted { layers.append(layer) }
        }}
        let art = base.art, style = base.style, seed = nextSeed()
        trialsQueue.async { [weak self] in
            guard let self else { return }
            let renderer = self.batchRenderer
            defer { renderer.context.clearCaches() }
            let materials = layers.map(PreparedMaterial.init)
            var produced = 0
            // Variations render concurrently and arrive in order, like a new set.
            Concurrent.ordered(count, width: 3, stop: { task.cancelled }) { i -> Trial? in
                if task.cancelled { return nil }
                return autoreleasepool {
                    // The row runs from close relatives to bolder ones.
                    let amount = 0.6 + 1.2 * Double(i) / Double(max(1, count - 1))
                    let varied = TrialGenerator.vary(art, materials: materials, seed: seed &+ UInt64(i + 1), amount: amount)
                    guard let image = renderer.render(varied, longEdge: 480) else { return nil }
                    return Trial(number: 0, style: style, art: varied, thumbnail: image)
                }
            } deliver: { _, trial in
                guard let trial, !task.cancelled else { return }
                produced += 1; let first = produced == 1
                DispatchQueue.main.async {
                    guard self.trialJob === task, !task.cancelled else { return }
                    if first { self.groups.insert(group, at: 0) }
                    self.append(trial, to: group)
                    self.trialMessage = "Making variations · \(self.trialProgress) of \(count)"
                }
            }
            if task.cancelled { return }
            DispatchQueue.main.async {
                guard self.trialJob === task, !task.cancelled else { return }
                self.makingTrials = false
                self.trialMessage = "\(produced) variations of \(base.title)"
                if produced == 0 { self.error = "The variations couldn’t render. Your previews are unchanged." }
                self.status = self.trialMessage
            }
        }
    }

    /// Copies a full-size PNG of a preview (or the open refinement) to the clipboard.
    func copyImage(of id: UUID? = nil) {
        storeActiveTrial()
        guard !copying, let id = id ?? commandTarget,
              let trial = trials.first(where: { $0.id == id }) else { return }
        copying = true
        let snapshot = trial.art, title = trial.title
        exportQueue.async { [weak self] in
            guard let self else { return }
            let data: (png: Data, tiff: Data?)? = autoreleasepool {
                guard let cg = Renderer.renderAlone(snapshot, longEdge: 2400) else { return nil }
                guard let png = PNGExport.data(cg) else { return nil }
                return (png, NSBitmapImageRep(cgImage: cg).tiffRepresentation)
            }
            DispatchQueue.main.async {
                self.copying = false
                guard let data else { self.error = "Couldn’t copy the image."; return }
                let item = NSPasteboardItem()
                item.setData(data.png, forType: .png)
                if let tiff = data.tiff { item.setData(tiff, forType: .tiff) }
                self.pasteboard.clearContents(); self.pasteboard.writeObjects([item])
                self.status = "Copied \(title)"
            }
        }
    }

    /// A lazily rendered 2400-pixel PNG for dragging a preview into Finder or another app.
    func dragProvider(for id: UUID) -> NSItemProvider {
        storeActiveTrial()
        let provider = NSItemProvider()
        guard let trial = trials.first(where: { $0.id == id }) else { return provider }
        let snapshot = trial.art, name = "Meld \(trial.title)"
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // One temporary folder; earlier drags are removed once receivers have had time to copy them.
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Meld drag", isDirectory: true)
                    let old = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
                    for item in old where ((try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < Date().addingTimeInterval(-600) {
                        try? FileManager.default.removeItem(at: item)
                    }
                    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("\(name).png")
                    try autoreleasepool {
                        guard let cg = Renderer.renderAlone(snapshot, longEdge: 2400),
                              let png = PNGExport.data(cg) else { throw CocoaError(.fileWriteUnknown) }
                        try png.write(to: url)
                    }
                    completion(url, false, nil)
                } catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }
    func toggleFavourite(_ id: UUID) {
        if favouriteTrials.contains(id) { favouriteTrials.remove(id) }
        else if trials.contains(where: { $0.id == id }) { favouriteTrials.insert(id) }
        keepSelectionVisible()
    }
    /// The preview that menu commands act on: the open one, or the grid selection.
    var commandTarget: UUID? {
        switch stage {
        case .refine: return activeTrialID
        case .previews: return gridSelection
        case .material: return nil
        }
    }
    /// When a pick change or the Picks filter hides the selection, select its nearest visible neighbour.
    private func keepSelectionVisible() {
        guard stage == .previews, let id = gridSelection else { return }
        let visible = Set(visibleTrials.map(\.id))
        guard !visible.contains(id) else { return }
        let ordered = orderedTrials
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { gridSelection = nil; return }
        gridSelection = (ordered[index...].first { visible.contains($0.id) } ?? ordered[..<index].last { visible.contains($0.id) })?.id
    }
    func openTrial(_ id: UUID) {
        guard !makingTrials else { return }
        if activeTrialID == id { return }
        storeActiveTrial()
        guard let trial = trials.first(where: { $0.id == id }) else { return }
        cancelPreview(); previewLongEdge = 1000
        preview = NSImage(cgImage: trial.thumbnail, size: .zero)
        art = trial.art; refinement = trial.refinement
        history = []; future = []; refinementHistory = []; refinementFuture = []; lastKey = ""
        activeTrialID = id; gridSelection = id; stage = .refine; revision += 1; palette = []
        selected = trial.art.layers.first(where: { $0.material == .image })?.id
        comparing = false; schedule()
        surpriseRevision += 1; status = trial.title
    }
    var activeTrial: Trial? { trials.first { $0.id == activeTrialID } }
    func setRefinement(_ key: String, value: Double) {
        guard let original = activeTrial?.original, value.isFinite, ["distortion", "pattern", "colour"].contains(key) else { return }
        let previous = key == "distortion" ? refinement.distortion : key == "colour" ? refinement.colour : refinement.pattern
        change(key) { Refinement.apply(key, value: value, previous: previous, original: original, to: &$0) }
        switch key {
        case "distortion": refinement.distortion = value
        case "colour": refinement.colour = value
        default: refinement.pattern = value
        }
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
        exportQueue.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter()
            // A fixed locale keeps the 24-hour folder name regardless of the user's clock setting.
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let folder = parent.appendingPathComponent("Meld picks \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6))", isDirectory: true)
            var completed = 0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                // A few picks render and encode at once; the contact sheet keeps their chosen order.
                let outcome = TrialExporter.write(chosen, into: folder, cancelled: { task.cancelled }) { progress in
                    DispatchQueue.main.async { self.trialExportProgress = progress }
                }
                let exported = outcome.exported
                completed = exported.count
                if let failure = outcome.failure { throw failure }
                if completed > 0, let contact = TrialGenerator.contactSheet(exported) {
                    try contact.write(to: folder.appendingPathComponent("Contact sheet.png"), options: .withoutOverwriting)
                }
                DispatchQueue.main.async {
                    self.exportingTrials = false
                    self.status = "\(task.cancelled ? "Stopped export; saved" : "Exported") \(completed) preview\(completed == 1 ? "" : "s") in \(folder.lastPathComponent)"
                    self.trialMessage = self.status
                }
            } catch {
                DispatchQueue.main.async {
                    self.exportingTrials = false
                    self.error = "Couldn’t finish exporting picks: \(error.localizedDescription). \(completed) PNGs were saved in \(folder.lastPathComponent)."
                }
            }
        }
    }
    func cancelTrialExport() { trialExportJob.cancel() }
    func export() {
        let p = NSSavePanel(); p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "Meld \(activeTrial?.title ?? "image").png"
        p.message = "Export this preview as a PNG (2400 pixels on the longest side)"
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            p.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = p.url { self?.export(to: url) }
            }
        } else if p.runModal() == .OK, let url = p.url { export(to: url) }
    }
    func export(to url: URL) {
        guard !exporting else { return }
        exporting = true; let snapshot = art
        exportQueue.async { [weak self] in
            guard let self else { return }
            do {
                try autoreleasepool {
                    guard let cg = Renderer.renderAlone(snapshot, longEdge: 2400),
                          let data = PNGExport.data(cg) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                }
                DispatchQueue.main.async { self.exporting = false; self.status = "Exported \(url.lastPathComponent)" }
            } catch { DispatchQueue.main.async { self.exporting = false; self.error = "Couldn’t export: \(error.localizedDescription)" } }
        }
    }
}
