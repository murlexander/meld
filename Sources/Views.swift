import SwiftUI
import AppKit

private let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.28, green: 0.65, blue: 0.62, alpha: 1)
        : NSColor(srgbRed: 0.16, green: 0.49, blue: 0.47, alpha: 1)
})
private let panel = Color(nsColor: .controlBackgroundColor)
// Explicit alias avoids the SDK's new State macro with command-line toolchains.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct StudioView: View {
    @ObservedObject var studio: Studio
    private enum Panel: String { case layers, adjust }
    @ViewState private var activePanel: Panel = .adjust
    @ViewState private var dropTarget = false
    @ViewState private var statusHint: String?
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 235, ideal: 250, max: 290)
        } detail: {
            HStack(spacing: 0) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    Picker("Controls", selection: $activePanel) {
                        Text("Layer").tag(Panel.layers)
                        Text("Canvas").tag(Panel.adjust)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.large).padding(16)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if activePanel == .layers { layerControls } else { warpControls }
                        }.font(.system(size: 13)).controlSize(.regular).padding(.horizontal, 18).padding(.bottom, 18)
                    }
                }.frame(width: 280).background(.bar)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1050, minHeight: 700)
        .navigationTitle("Meld")
        .tint(accent).accentColor(accent)
        .toolbar { toolbar }
        .alert("Meld", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("OK") { studio.error = nil }
        } message: { Text(studio.error ?? "") }
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
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { studio.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!studio.canUndo).accessibilityLabel("Undo").help("Undo (⌘Z)")
            Button { studio.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!studio.canRedo).accessibilityLabel("Redo").help("Redo (⇧⌘Z)")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            Toggle(isOn: Binding(get: { studio.comparing }, set: { studio.comparing = $0; studio.schedule() })) {
                Image(systemName: "square.lefthalf.filled")
            }
            .toggleStyle(.button).accessibilityLabel("Before distortions")
            .help(studio.comparing ? "Show distortions" : "Before distortions")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            Button { studio.export() } label: {
                Image(systemName: "square.and.arrow.up").offset(y: -1)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(accent)
            .disabled(studio.exporting).accessibilityLabel("Export PNG").help("Export PNG (⌘E)")
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Text("\(studio.art.layers.count)").foregroundStyle(.secondary)
                Button { studio.importPanel() } label: { Image(systemName: "photo.badge.plus") }
                    .modifier(StudioButtons()).controlSize(.large)
                    .accessibilityLabel("Add images").help("Add images (⌘I)")
            }.padding(.horizontal, 16).padding(.vertical, 14)
            layers
            Divider()
            sourceControls.padding(16)
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
                Button { studio.randomize(); activePanel = .adjust } label: {
                    Label(studio.gathering ? "Mixing…" : "Surprise me", systemImage: "shuffle")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 30)
                }.modifier(StudioButtons(prominent: true)).controlSize(.large)
                    .disabled(studio.materialsBusy).keyboardShortcut("r").help("Make another mix (⌘R)")
            }.padding(16)
        }.font(.system(size: 13))
    }
    var sourceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source material").font(.headline)
            Button { studio.chooseSourceFolder() } label: {
                Label(studio.sourceFolder?.lastPathComponent ?? "Choose folder…", systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }.modifier(StudioButtons()).controlSize(.large).help(studio.sourceFolder?.path ?? "Choose material for Surprise me")
            if studio.sourceFolder != nil {
                HStack {
                    Text(studio.sourceMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Rescan folder") { studio.refreshSource() }.disabled(studio.materialsBusy)
                        Button("Disconnect folder") { studio.clearSourceFolder() }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        .help("Source folder options").accessibilityLabel("Source folder options")
                }
            }
        }
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
    @ViewBuilder func thumbnail(_ layer: Layer) -> some View {
        if let data = layer.image, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let image = Renderer.pattern(layer, w: 80, h: 80) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
        } else { Rectangle().fill(layer.ink.color) }
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
                        guard activePanel == .adjust, !studio.comparing else { return }
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
                    Text(studio.comparing ? "Before distortions" : studio.gathering ? "Mixing…" : studio.importing ? "Adding images…" : studio.exporting ? "Exporting…" : studio.sourceScanning ? "Looking for images…" : studio.rendering ? "Updating…" : statusHint ?? "")
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
                    Button("Reset placement") { studio.updateLayer("reset") { $0.scale = 1; $0.rotation = 0; $0.x = 0; $0.y = 0 } }.font(.system(size: 13))
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
private struct StudioButtons: ViewModifier {
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
