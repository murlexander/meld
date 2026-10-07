import SwiftUI
import AppKit

private let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.28, green: 0.65, blue: 0.62, alpha: 1)
        : NSColor(srgbRed: 0.16, green: 0.49, blue: 0.47, alpha: 1)
})
// Explicit alias avoids the SDK's new State macro with command-line toolchains.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct StudioView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        Group {
            switch studio.stage {
            case .material: MaterialView(studio: studio)
            case .previews: TrialsView(studio: studio)
            case .refine: RefinementView(studio: studio).id(studio.activeTrialID)
            }
        }.frame(minWidth: 1050, minHeight: 700)
            .tint(accent).accentColor(accent)
            .alert("Meld", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
                Button("OK") { studio.error = nil }
            } message: { Text(studio.error ?? "") }
    }
}

struct RefinementView: View {
    @ObservedObject var studio: Studio
    private enum Panel: String { case layers, adjust }
    @ViewState private var activePanel: Panel = .adjust
    @ViewState private var inspectorVisible = true
    @ViewState private var detailed = false
    @ViewState private var columns: NavigationSplitViewVisibility = .detailOnly
    @ViewState private var dropTarget = false
    @ViewState private var statusHint: String?
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 235, ideal: 250, max: 290)
        } detail: {
            canvas.toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        // Let the native sidebar and inspector own their full-height material.
        // A writable binding also tracks collapse by dragging the divider.
        .inspector(isPresented: $inspectorVisible) {
            controls.inspectorColumnWidth(280)
        }
        .frame(minWidth: 1050, minHeight: 700)
        .navigationTitle("")
        .tint(accent).accentColor(accent)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: detailed) { _, expanded in columns = expanded ? .all : .detailOnly }
        .onChange(of: studio.selected) { _, _ in activePanel = .layers }
        .onChange(of: studio.surpriseRevision) { _, _ in activePanel = .adjust }
        .onChange(of: studio.status) { _, message in statusHint = message }
        .task(id: statusHint) {
            guard statusHint != nil else { return }
            do { try await Task.sleep(for: .seconds(4)); statusHint = nil }
            catch { } // A newer message restarts the timer.
        }
        .onOpenURL { url in
            studio.importImages([url])
        }
    }
    private var controls: some View {
        VStack(spacing: 0) {
            if detailed {
                HStack {
                    Picker("Controls", selection: $activePanel) {
                        Text("Layer").tag(Panel.layers); Text("Canvas").tag(Panel.adjust)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                }.padding(16)
            } else {
                HStack { Text("A few adjustments").font(.headline); Spacer() }.padding(18)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if detailed {
                        if activePanel == .layers { layerControls } else { warpControls }
                    } else {
                        dial("Distortion", value: Binding(get: { studio.refinement.distortion }, set: { studio.setRefinement("distortion", value: $0) }),
                             range: 0...1.75, defaultValue: 1, format: .percent)
                        dial("Pattern amount", value: Binding(get: { studio.refinement.pattern }, set: { studio.setRefinement("pattern", value: $0) }),
                             range: 0...1.5, defaultValue: 1, format: .percent)
                        dial("Colour", value: warpValue(\.saturation, "saturation"), range: 0...2,
                             defaultValue: studio.activeTrial?.original.warp.saturation ?? 1, format: .percent)
                        dial("Contrast", value: warpValue(\.contrast, "contrast"), range: 0.5...1.5,
                             defaultValue: studio.activeTrial?.original.warp.contrast ?? 1, format: .percent)
                        Button("Reset preview") { studio.resetActiveTrial() }.modifier(StudioButtons())
                    }
                    Divider()
                    Button(detailed ? "Simple controls" : "More controls…") { detailed.toggle() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.system(size: 13)).controlSize(.regular).padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }
    // Keep panel recovery in the detail toolbar, outside the collapsible inspector.
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { toolbarTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { toolbarTitle }
        }
        ToolbarItem(placement: .navigation) {
            Button { studio.showTrials() } label: { Label("Previews", systemImage: "chevron.left") }
                .help("Return to all previews; adjustments stay with this one")
        }
        ToolbarItemGroup {
            Button { studio.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!studio.canUndo).accessibilityLabel("Undo").help("Undo (⌘Z)")
            Button { studio.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!studio.canRedo).accessibilityLabel("Redo").help("Redo (⇧⌘Z)")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItemGroup {
            Toggle(isOn: Binding(get: { studio.comparing }, set: { studio.comparing = $0; studio.schedule() })) {
                Image(systemName: "square.lefthalf.filled")
            }
            .toggleStyle(.button).accessibilityLabel("Original preview")
            .help(studio.comparing ? "Show adjustments" : "Compare with the generated preview")
            Toggle(isOn: $inspectorVisible) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .accessibilityLabel(inspectorVisible ? "Hide controls" : "Show controls")
            .help(inspectorVisible ? "Hide controls" : "Show controls")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            Button {
                if let id = studio.activeTrialID { studio.toggleFavourite(id) }
            } label: { Image(systemName: studio.activeTrialID.map { studio.favouriteTrials.contains($0) } == true ? "star.fill" : "star") }
                .accessibilityLabel("Pick this preview").help("Include this preview when exporting picks")
        }
        ToolbarItem {
            Button { studio.export() } label: {
                Image(systemName: "square.and.arrow.up").offset(y: -1)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(accent)
            .disabled(studio.exporting).accessibilityLabel("Export PNG").help("Export PNG (⌘E)")
        }
    }
    private var toolbarTitle: some View {
        Text(studio.activeTrial?.title ?? "Meld").font(.subheadline).foregroundStyle(.secondary)
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Text("\(studio.art.layers.count)").foregroundStyle(.secondary)
                Button { studio.importPanel() } label: { Image(systemName: "photo.badge.plus") }
                    .modifier(StudioButtons()).controlSize(.large)
                    .accessibilityLabel("Add images").keyboardShortcut("i").help("Add images (⌘I)")
            }.padding(.horizontal, 16).padding(.vertical, 14)
            layers
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a pattern").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Material.allCases.filter { $0 != .image }, id: \.self) { material in
                        Button {
                            studio.addPattern(material); activePanel = .layers
                        } label: {
                            Label(material.label, systemImage: material.symbol)
                                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        }
                    }
                }.modifier(StudioButtons()).controlSize(.large)
            }.padding(16)
        }.font(.system(size: 13))
    }
    var layers: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { studio.selected }, set: { studio.selected = $0; activePanel = .layers })) {
                ForEach(Array(studio.art.layers.reversed())) { layer in
                    HStack(spacing: 9) {
                        thumbnail(layer).frame(width: 42, height: 46).clipped().cornerRadius(4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(layer.name).lineLimit(1)
                            Text(layer.blend.label + " · " + String(Int(layer.opacity * 100)) + "%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            studio.change("visible-\(layer.id)-\(UUID())") { a in
                                if let i = a.layers.firstIndex(where: { $0.id == layer.id }) { a.layers[i].visible.toggle() }
                            }
                        } label: { Image(systemName: layer.visible ? "eye" : "eye.slash").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel((layer.visible ? "Hide " : "Show ") + layer.name)
                    }
                    .font(.system(size: 13)).padding(.vertical, 4)
                    .contentShape(Rectangle()).tag(layer.id)
                    .help(layer.sourcePath ?? "Drag to reorder " + layer.name)
                    .contextMenu {
                        Button("Duplicate") { studio.selected = layer.id; studio.duplicate() }
                        Divider()
                        Button("Remove layer") { studio.selected = layer.id; studio.remove() }
                    }
                }
                .onMove { offsets, destination in
                    studio.reorderLayers(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .frame(minHeight: 140, maxHeight: .infinity)

        }
    }
    func thumbnail(_ layer: Layer) -> some View {
        LayerThumbnail(layer: layer).equatable()
    }
    var canvas: some View {
        ZoomCanvas(ratio: studio.art.ratio, tint: accent, resolutionChanged: studio.setMagnifiedPreview) { size in
                let w = size.width
                let h = size.height
                ZStack {
                    if let preview = studio.preview {
                        Image(nsImage: preview).resizable().interpolation(.high).scaledToFit()
                    }
                    if studio.art.layers.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 34, weight: .light))
                            Text("Start with a picture.\nOr just a pattern.").font(.system(size: 23, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                            Button("Choose images…") { studio.importPanel() }.buttonStyle(.bordered)
                        }.foregroundStyle(Color(red: 0.22, green: 0.25, blue: 0.3))
                    }
                    if dropTarget { Rectangle().fill(accent.opacity(0.15)).overlay { RoundedRectangle(cornerRadius: 3).stroke(accent, lineWidth: 3) } }
                }.frame(width: w, height: h)
                    .background(.white).shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard detailed, activePanel == .adjust, !studio.comparing else { return }
                        studio.change("warp-center") { a in
                            a.warp.centerX = min(1, max(0, value.location.x / w))
                            a.warp.centerY = min(1, max(0, value.location.y / h))
                        }
                    })
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if studio.materialsBusy || studio.rendering || studio.exporting || studio.comparing || statusHint != nil {
                HStack(spacing: 6) {
                    if studio.materialsBusy || studio.rendering || studio.exporting { ProgressView().controlSize(.mini) }
                    Text(studio.comparing ? "Original preview" : studio.gathering ? "Mixing…" : studio.importing ? "Adding images…" : studio.exporting ? "Exporting…" : studio.sourceScanning ? "Looking for images…" : studio.rendering ? "Updating…" : statusHint ?? "")
                }.font(.caption).lineLimit(2).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule()).padding(8).padding(.bottom, 48).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = item as? URL }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        studio.importImages([url])
                    }
                }
            }; return true
        }
    }
    @ViewBuilder var layerControls: some View {
        if let layer = studio.current {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Layer name", text: Binding(get: { studio.current?.name ?? "" }, set: { value in studio.updateLayer("name") { $0.name = value } }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .semibold))
                Picker("Blend", selection: Binding(get: { studio.current?.blend ?? .normal }, set: { value in studio.updateLayer("blend") { $0.blend = value } })) {
                    ForEach(Blend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                dial("Opacity", value: layerValue(\.opacity, "opacity"), range: 0...1, defaultValue: 1, format: .percent)
            }
            if layer.material != .image {
                Divider()
                sectionTitle("Pattern")
                Picker("Shape", selection: Binding(get: { studio.current?.material ?? .stripes }, set: { v in studio.updateLayer("material") { $0.material = v } })) {
                    ForEach(Material.allCases.filter { $0 != .image }, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    ColorPicker("Ink", selection: Binding(get: { studio.current?.ink.color ?? .black }, set: { v in studio.updateLayer("ink") { $0.ink = Ink(v) } }), supportsOpacity: false)
                    ColorPicker("Paper", selection: Binding(get: { studio.current?.paper.color ?? .white }, set: { v in studio.updateLayer("paper") { $0.paper = Ink(v) } }), supportsOpacity: false)
                }.font(.system(size: 13))
                dial("Repeat", value: layerValue(\.frequency, "repeat"), range: 2...60, defaultValue: 12, format: .number)
            }
            Divider()
            DisclosureGroup("Placement") {
                VStack(spacing: 14) {
                    dial("Scale", value: layerValue(\.scale, "scale"), range: 0.1...3, defaultValue: 1, format: .percent)
                    dial("Rotate", value: layerValue(\.rotation, "rotation"), range: -180...180, defaultValue: 0, format: .degrees)
                    dial("Horizontal", value: layerValue(\.x, "x"), range: -0.75...0.75, defaultValue: 0, format: .percent)
                    dial("Vertical", value: layerValue(\.y, "y"), range: -0.75...0.75, defaultValue: 0, format: .percent)
                    if layer.material == .image {
                        Stepper("Mirrored tiles: \(layer.tiles == 1 ? "Off" : String(layer.tiles))", value: Binding(
                            get: { studio.current?.tiles ?? 1 },
                            set: { value in studio.updateLayer("tiles") { $0.tiles = value } }), in: 1...8)
                    }
                    Button("Reset placement") { studio.updateLayer("reset") { $0.scale = 1; $0.rotation = 0; $0.x = 0; $0.y = 0; $0.tiles = 1 } }.font(.system(size: 13))
                }.padding(.top, 10)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Pick a layer")
                Text("Add an image or pattern to begin.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    var warpControls: some View {
        Group {
            Picker("Shape", selection: Binding(get: { studio.art.aspect }, set: { value in studio.change("aspect") { $0.aspect = value } })) {
                Text("Square").tag("Square"); Text("Portrait").tag("Portrait"); Text("Landscape").tag("Landscape")
            }
            HStack(spacing: 6) {
                ForEach(["Flow", "Vortex", "Blocks"], id: \.self) { name in
                    Button { studio.preset(name) } label: {
                        Text(name).frame(maxWidth: .infinity, minHeight: 24)
                    }
                }
            }.modifier(StudioButtons()).controlSize(.large)
            Divider()
            dial("Wave", value: warpValue(\.wave, "wave"), range: 0...1, defaultValue: 0, format: .percent)
            dial("Twist", value: warpValue(\.twist, "twist"), range: -5...5, defaultValue: 0, format: .decimal)
            dial("Bulge", value: warpValue(\.bulge, "bulge"), range: -0.9...0.9, defaultValue: 0, format: .percent)
            dial("Pixelate", value: warpValue(\.pixel, "pixel"), range: 0...1, defaultValue: 0, format: .percent)
            if studio.art.warp.twist != 0 || studio.art.warp.bulge != 0 {
                Text("Drag on the artwork to move the centre.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                    dial("Wave frequency", value: warpValue(\.wavelength, "wavelength"), range: 1...12, defaultValue: 3, format: .decimal)
                    dial("Saturation", value: warpValue(\.saturation, "saturation"), range: 0...2, defaultValue: 1, format: .percent)
                    dial("Contrast", value: warpValue(\.contrast, "contrast"), range: 0.5...1.5, defaultValue: 1, format: .percent)
                    ColorPicker("Canvas colour", selection: Binding(get: { studio.art.background.color }, set: { v in studio.change("background") { $0.background = Ink(v) } }), supportsOpacity: false)
            }
            Button("Reset adjustments") { studio.change("reset-warp") { $0.warp = Warp() } }.modifier(StudioButtons()).controlSize(.large)
        }
    }
    func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 13, weight: .semibold)) }
    func layerValue(_ path: WritableKeyPath<Layer, Double>, _ key: String) -> Binding<Double> {
        Binding(get: { studio.current?[keyPath: path] ?? 0 }, set: { value in studio.updateLayer(key) { $0[keyPath: path] = value } })
    }
    func warpValue(_ path: WritableKeyPath<Warp, Double>, _ key: String) -> Binding<Double> {
        Binding(get: { studio.art.warp[keyPath: path] }, set: { value in studio.change(key) { $0.warp[keyPath: path] = value } })
    }
    enum DialFormat { case percent, number, decimal, degrees }
    func dial(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double, format: DialFormat) -> some View {
        let label: String
        switch format { case .percent: label = "\(Int(value.wrappedValue * 100))%"; case .number: label = "\(Int(value.wrappedValue))"; case .decimal: label = String(format: "%.1f", value.wrappedValue); case .degrees: label = "\(Int(value.wrappedValue))°" }
        return VStack(spacing: 5) {
            HStack { Text(name); Spacer(); Text(label).foregroundStyle(.secondary).monospacedDigit() }.font(.system(size: 13))
            ResettableSlider(value: value, range: range, label: name, reset: { value.wrappedValue = defaultValue })
        }
    }
}

// Native glass controls on current macOS; ordinary native buttons on older systems.
struct StudioButtons: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                if prominent { content.buttonStyle(.glassProminent) }
                else { content.buttonStyle(.glass).tint(nil) }
            }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered).tint(nil) }
        }
    }
}

// Geometry, opacity and selection changes do not rebuild sidebar image thumbnails.
private struct LayerThumbnail: View, Equatable {
    let layer: Layer
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layer.image == rhs.layer.image && lhs.layer.material == rhs.layer.material &&
        lhs.layer.frequency == rhs.layer.frequency && lhs.layer.ink == rhs.layer.ink && lhs.layer.paper == rhs.layer.paper
    }
    var body: some View {
        if let image = layer.image?.thumbnail {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else if let image = Renderer.pattern(layer, w: 80, h: 80) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else { Rectangle().fill(layer.ink.color) }
    }
}
