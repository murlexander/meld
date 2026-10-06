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
    private let materialsQueue = DispatchQueue(label: "Meld.materials", qos: .userInitiated)
    private let materialLoader = MaterialLoader()
    private var scanToken = UUID()
    private var surpriseToken = UUID()
    private var lastMaterials: Set<URL> = []
    private var pendingImports = 0
    private let restoreSource: Bool
    private var history: [Artwork] = []
    private var future: [Artwork] = []
    private var lastKey = ""
    private var lastChange = Date.distantPast
    private var job: DispatchWorkItem?
    private let queue = DispatchQueue(label: "Meld.render", qos: .userInitiated)
    private var generation = 0
    let renderer = Renderer()
    var current: Layer? { art.layers.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(restoreSource: Bool = true) {
        self.restoreSource = restoreSource
        loadStarter(record: false)
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
        panel.message = "Choose photos, RAW files, or textures for Surprise me"
        panel.directoryURL = sourceFolder
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] result in
                if result == .OK, let url = panel.url { self?.setSourceFolder(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url { setSourceFolder(url) }
    }
    func setSourceFolder(_ url: URL, scan: Bool = true) {
        scanToken = UUID(); sourceScanning = false
        surpriseToken = UUID(); gathering = false; lastMaterials = []
        sourceFolder = url; sourceCount = 0
        if restoreSource {
            UserDefaults.standard.set(url.path, forKey: "source.path")
            if let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: "source.bookmark")
            }
        }
        if scan { refreshSource() }
        else { sourceMessage = "Ready for the next mix." }
    }
    func clearSourceFolder() {
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
            if history.count > 50 { history.removeFirst() }
        }
        lastKey = key; lastChange = Date(); future.removeAll()
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
        future.append(art); art = previous; finishHistory()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        history.append(art); art = next; finishHistory()
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
        let token = generation; let snapshot = art; let raw = comparing; let edge = previewLongEdge
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
            a.warp.wave = Double.random(in: 0...0.5); a.warp.twist = Double.random(in: -2.2...2.2)
            a.warp.bulge = Double.random(in: -0.5...0.6); a.warp.wavelength = Double.random(in: 1.5...7)
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
                var composition = snapshot
                composition.layers = loaded.map(\.layer)
                for i in composition.layers.indices {
                    composition.layers[i].scale = Double.random(in: 1.05...1.55)
                    composition.layers[i].rotation = Double.random(in: -35...35)
                    composition.layers[i].x = Double.random(in: -0.16...0.16)
                    composition.layers[i].y = Double.random(in: -0.16...0.16)
                    if i > 0 {
                        composition.layers[i].opacity = Double.random(in: 0.3...0.7)
                        composition.layers[i].blend = [Blend.multiply, .screen, .overlay, .softLight, .difference].randomElement()!
                    }
                }
                let pattern = [Material.stripes, .dots, .checker, .rings, .noise].randomElement()!
                composition.layers.append(Layer(name: pattern.label, material: pattern, opacity: Double.random(in: 0.12...0.35), blend: .softLight,
                    rotation: Double.random(in: -90...90), frequency: Double.random(in: 5...24),
                    ink: Ink(Double.random(in: 0.1...0.5), Double.random(in: 0.1...0.5), Double.random(in: 0.1...0.5)),
                    paper: Ink(Double.random(in: 0.6...1), Double.random(in: 0.6...1), Double.random(in: 0.6...1))))
                composition.warp = Warp(); Self.shuffleEffects(&composition)
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
                    self.change("surprise-\(UUID())") { $0 = composition }
                    self.selected = composition.layers.first?.id
                    // Comparing should not accidentally conceal the new effects.
                    if self.comparing { self.comparing = false; self.schedule() }
                    self.status = "Mixed \(loaded.count) source image\(loaded.count == 1 ? "" : "s"). Undo takes you back."
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
