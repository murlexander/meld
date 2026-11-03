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
    var studio: Studio
    var body: some View {
        Group {
            switch studio.stage {
            case .material: MaterialView(studio: studio)
            case .previews: TrialsView(studio: studio)
            case .refine: RefinementView(studio: studio)
            }
        }.frame(minWidth: 1050, minHeight: 700)
            .tint(accent).accentColor(accent)
            .alert("Meld", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
                Button("OK") { studio.error = nil }
            } message: { Text(studio.error ?? "") }
    }
}

struct RefinementView: View {
    var studio: Studio
    private enum Panel: String { case layers, adjust }
    @ViewState private var activePanel: Panel = .adjust
    @ViewState private var inspectorVisible = true
    /// UI snapshots open refinement with More controls showing.
    static var startsDetailed = false
    @ViewState private var detailed = RefinementView.startsDetailed
    @ViewState private var columns: NavigationSplitViewVisibility = .detailOnly
    @ViewState private var dropTarget = false
    @ViewState private var statusHint: String?
    @FocusState private var editingName: Bool
    @ViewState private var shownTrialID: UUID?
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 235, ideal: 250, max: 290)
        } detail: {
            canvas.background {
                RefinementToolbar(studio: studio, inspectorVisible: inspectorVisible, showInspector: $inspectorVisible, editingName: editingName).equatable()
            }
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
        .onAppear { shownTrialID = studio.activeTrialID }
        .onChange(of: studio.selected) { _, _ in
            // Opening another preview selects its image layer; that should not switch panels.
            if shownTrialID != studio.activeTrialID { shownTrialID = studio.activeTrialID; activePanel = .adjust }
            else { activePanel = .layers }
        }
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
                        dial("Colour", value: Binding(get: { studio.refinement.colour }, set: { studio.setRefinement("colour", value: $0) }),
                             range: 0...2, defaultValue: 1, format: .percent)
                        dial("Contrast", value: warpValue(\.contrast, "contrast"), range: 0.5...1.5,
                             defaultValue: studio.activeTrial?.original.warp.contrast ?? 1, format: .percent)
                        HStack(spacing: 8) {
                            Button("Reset preview") { studio.resetActiveTrial() }
                            Button("Variations") { if let id = studio.activeTrialID { studio.makeVariations(of: id) } }
                                .help("Make 12 variations of this preview, including your adjustments")
                                .disabled(!studio.canMakeVariations)
                        }.modifier(StudioButtons())
                    }
                    Divider()
                    studySection
                    paletteSection
                    Divider()
                    Button(detailed ? "Simple controls" : "More controls…") { detailed.toggle() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }.font(.system(size: 13)).controlSize(.regular).padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }
    private var studySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View").font(.headline)
            Picker("View", selection: Binding(get: { studio.study }, set: { studio.setStudy($0) })) {
                ForEach(Study.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .help("Values and Notan only change the view; exports stay in colour")
        }
    }
    @ViewBuilder private var paletteSection: some View {
        if !studio.palette.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Palette").font(.headline)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(studio.palette.map(\.hex).joined(separator: "\n"), forType: .string)
                    }.buttonStyle(.link).help("Copy all colours as hex values")
                }
                HStack(spacing: 6) {
                    ForEach(Array(studio.palette.enumerated()), id: \.offset) { _, ink in
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ink.hex, forType: .string)
                        } label: {
                            RoundedRectangle(cornerRadius: 5).fill(ink.color)
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator) }
                                .frame(height: 30)
                        }.buttonStyle(.plain).help("\(ink.hex) · click to copy").accessibilityLabel("Colour \(ink.hex)")
                    }
                }
            }
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
        // Each preview opens at Fit; panels and inspector stay as arranged. Resetting the zoom
        // instead of recreating the canvas avoids relaying out the whole window and toolbar.
        ZoomCanvas(ratio: studio.art.ratio, tint: accent, fitWhenChanged: studio.activeTrialID, resolutionChanged: studio.setMagnifiedPreview) { size in
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
                    .textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .semibold)).focused($editingName)
                Picker("Blend", selection: Binding(get: { studio.current?.blend ?? .normal }, set: { value in studio.updateLayer("blend") { $0.blend = value } })) {
                    ForEach(Blend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                dial("Opacity", value: layerValue(\.opacity, "opacity"), range: 0...1, defaultValue: 1, format: .percent)
                if layer.material == .image { maskControls(layer) }
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
                        dial("Stretch", value: layerValue(\.stretch, "stretch"), range: 1...Refinement.maximumStretch, defaultValue: 1, format: .percent)
                        if layer.stretch > 1.001 {
                            dial("Stretch angle", value: layerValue(\.stretchAngle, "stretch-angle"), range: -90...90, defaultValue: 0, format: .degrees)
                        }
                        Stepper("Mirrored tiles: \(layer.tiles == 1 ? "Off" : String(layer.tiles))", value: Binding(
                            get: { studio.current?.tiles ?? 1 },
                            set: { value in studio.updateLayer("tiles") { $0.tiles = value } }), in: 1...8)
                    }
                    Button("Reset placement") { studio.updateLayer("reset") { $0.scale = 1; $0.rotation = 0; $0.x = 0; $0.y = 0; $0.tiles = 1; $0.stretch = 1; $0.stretchAngle = 0 } }.font(.system(size: 13))
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
            Divider()
            effectControls
            Button("Reset adjustments") { studio.change("reset-warp") { $0.warp = Warp(); $0.effects = Effects() } }.modifier(StudioButtons()).controlSize(.large)
        }
    }
    /// Where an image layer shows. The radial centre is shown, not edited.
    @ViewBuilder func maskControls(_ layer: Layer) -> some View {
        Picker("Mask", selection: Binding(get: { studio.current?.mask ?? .none }, set: { kind in
            studio.updateLayer("mask") { l in
                guard l.mask != kind else { return }
                l.mask = kind
                switch kind { case .bright, .dark: l.maskPosition = 0.5; case .linear: l.maskPosition = 0; case .radial: l.maskPosition = 0.3; case .none: break }
            }
        })) { ForEach(MaskKind.allCases, id: \.self) { Text($0.label).tag($0) } }
        switch layer.mask {
        case .none: EmptyView()
        case .bright, .dark:
            dial("Threshold", value: layerValue(\.maskPosition, "mask-position"), range: 0...1, defaultValue: 0.5, format: .percent)
            dial("Softness", value: layerValue(\.maskSoftness, "mask-softness"), range: 0.01...0.5, defaultValue: 0.2, format: .percent)
        case .linear:
            dial("Fade position", value: layerValue(\.maskPosition, "mask-position"), range: -0.5...0.5, defaultValue: 0, format: .percent)
            dial("Softness", value: layerValue(\.maskSoftness, "mask-softness"), range: 0.01...0.5, defaultValue: 0.2, format: .percent)
            dial("Fade angle", value: layerValue(\.maskAngle, "mask-angle"), range: -180...180, defaultValue: 0, format: .degrees)
        case .radial:
            dial("Radius", value: layerValue(\.maskPosition, "mask-position"), range: 0.05...0.8, defaultValue: 0.3, format: .percent)
            dial("Softness", value: layerValue(\.maskSoftness, "mask-softness"), range: 0.01...0.5, defaultValue: 0.2, format: .percent)
            Text("Centre \(Int(layer.maskX * 100))% across, \(Int(layer.maskY * 100))% down").font(.caption).foregroundStyle(.secondary)
        }
    }
    /// Whole-image stages: mirror, colour treatment, blur and grain. Gradient colours are shown, not edited.
    @ViewBuilder var effectControls: some View {
        let effects = studio.art.effects
        Picker("Mirror", selection: Binding(get: { studio.art.effects.symmetry }, set: { v in studio.change("symmetry") { $0.effects.symmetry = v } })) {
            ForEach(Symmetry.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if effects.symmetry == .vertical || effects.symmetry == .both {
            dial("Mirror across", value: effectValue(\.splitX, "split-x"), range: 0.25...0.75, defaultValue: 0.5, format: .percent)
        }
        if effects.symmetry == .horizontal || effects.symmetry == .both {
            dial("Mirror down", value: effectValue(\.splitY, "split-y"), range: 0.25...0.75, defaultValue: 0.5, format: .percent)
        }
        Picker("Colour", selection: Binding(get: { studio.art.effects.colour }, set: { kind in
            let palette = studio.palette
            studio.change("colour-treatment") { a in
                a.effects.colour = kind
                if kind != .none && a.effects.colourMix < 0.01 { a.effects.colourMix = 1 }
                if (kind == .gradientMap || kind == .paletteSwap) && a.effects.colours.count < 2 {
                    a.effects.colours = palette.count >= 3 ? [palette.first!, palette[palette.count / 2], palette.last!] : [Ink(0.1, 0.12, 0.16), Ink(0.93, 0.9, 0.82)]
                }
                if kind == .hue && a.effects.hue == 0 { a.effects.hue = 15 }
            }
        })) { ForEach(ColourTreatment.allCases, id: \.self) { Text($0.label).tag($0) } }
        if effects.colour != .none {
            dial("Strength", value: effectValue(\.colourMix, "colour-mix"), range: 0...1, defaultValue: 1, format: .percent)
        }
        switch effects.colour {
        case .gradientMap, .paletteSwap:
            HStack(spacing: 4) {
                ForEach(Array(effects.colours.enumerated()), id: \.offset) { _, ink in
                    RoundedRectangle(cornerRadius: 3).fill(ink.color).frame(height: 16)
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.separator) }.help(ink.hex)
                }
            }.accessibilityLabel("Treatment colours")
        case .posterize:
            Stepper("Value bands: \(effects.levels)", value: Binding(get: { studio.art.effects.levels }, set: { v in studio.change("levels") { $0.effects.levels = v } }), in: 2...8)
        case .hue:
            dial("Hue shift", value: effectValue(\.hue, "hue"), range: -180...180, defaultValue: 0, format: .degrees)
        case .none: EmptyView()
        }
        Picker("Blur", selection: Binding(get: { studio.art.effects.blur }, set: { kind in
            studio.change("blur") { a in
                a.effects.blur = kind
                if kind != .none && a.effects.blurAmount < 0.001 { a.effects.blurAmount = 0.03; a.effects.blurMix = 0.6 }
            }
        })) { ForEach(BlurKind.allCases, id: \.self) { Text($0.label).tag($0) } }
        if effects.blur != .none {
            dial("Blur length", value: effectValue(\.blurAmount, "blur-amount"), range: 0...0.1, defaultValue: 0.03, format: .percent)
            dial("Blur mix", value: effectValue(\.blurMix, "blur-mix"), range: 0...1, defaultValue: 0.6, format: .percent)
            if effects.blur == .motion {
                dial("Blur angle", value: effectValue(\.blurAngle, "blur-angle"), range: -90...90, defaultValue: 0, format: .degrees)
            }
        }
        dial("Grain", value: effectValue(\.grain, "grain"), range: 0...0.3, defaultValue: 0, format: .percent)
    }
    func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 13, weight: .semibold)) }
    func layerValue(_ path: WritableKeyPath<Layer, Double>, _ key: String) -> Binding<Double> {
        Binding(get: { studio.current?[keyPath: path] ?? 0 }, set: { value in studio.updateLayer(key) { $0[keyPath: path] = value } })
    }
    func effectValue(_ path: WritableKeyPath<Effects, Double>, _ key: String) -> Binding<Double> {
        Binding(get: { studio.art.effects[keyPath: path] }, set: { value in studio.change(key) { $0.effects[keyPath: path] = value } })
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

/// The refinement toolbar, declared apart from the canvas and controls so adjustments don't
/// rebuild it: each item reads only what it shows. Panel recovery stays in the detail toolbar,
/// outside the collapsible inspector.
private struct RefinementToolbar: View, Equatable {
    let studio: Studio
    let inspectorVisible: Bool
    let showInspector: Binding<Bool>
    let editingName: Bool
    static func == (a: Self, b: Self) -> Bool {
        a.studio === b.studio && a.inspectorVisible == b.inspectorVisible && a.editingName == b.editingName
    }
    var body: some View {
        Color.clear.toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { Title(studio: studio) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { Title(studio: studio) }
            }
            ToolbarItem(placement: .navigation) {
                Button { studio.showTrials() } label: { Label("Previews", systemImage: "square.grid.2x2") }
                    .keyboardShortcut(editingName ? nil : .cancelAction)
                    .help("Return to all previews (Esc); adjustments stay with this one")
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .navigation) }
            ToolbarItem(placement: .navigation) { Neighbours(studio: studio) }
            ToolbarItemGroup {
                UndoButton(studio: studio)
                RedoButton(studio: studio)
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
            ToolbarItemGroup {
                CompareToggle(studio: studio)
                Toggle(isOn: showInspector) {
                    Image(systemName: "sidebar.right")
                }
                .toggleStyle(.button)
                .accessibilityLabel(inspectorVisible ? "Hide controls" : "Show controls")
                .help(inspectorVisible ? "Hide controls" : "Show controls")
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
            ToolbarItem { PickButton(studio: studio) }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
            ToolbarItem { ExportButton(studio: studio) }
        }
    }

    private struct Title: View {
        var studio: Studio
        var body: some View {
            Text(studio.activeTrial?.title ?? "Meld").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private struct Neighbours: View {
        var studio: Studio
        var body: some View {
            ControlGroup {
                Button { studio.openAdjacentTrial(-1) } label: { Label("Previous preview", systemImage: "chevron.left") }
                    .disabled(!studio.canOpenPrevious).help("Previous preview (⌘[)")
                Button { studio.openAdjacentTrial(1) } label: { Label("Next preview", systemImage: "chevron.right") }
                    .disabled(!studio.canOpenNext).help("Next preview (⌘])")
            }
        }
    }
    private struct UndoButton: View {
        var studio: Studio
        var body: some View {
            Button { studio.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!studio.canUndo).accessibilityLabel("Undo").help("Undo (⌘Z)")
        }
    }
    private struct RedoButton: View {
        var studio: Studio
        var body: some View {
            Button { studio.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!studio.canRedo).accessibilityLabel("Redo").help("Redo (⇧⌘Z)")
        }
    }
    private struct CompareToggle: View {
        var studio: Studio
        var body: some View {
            Toggle(isOn: Binding(get: { studio.comparing }, set: { studio.comparing = $0; studio.schedule() })) {
                Image(systemName: "square.lefthalf.filled")
            }
            .toggleStyle(.button).accessibilityLabel("Original preview")
            .help(studio.comparing ? "Show adjustments" : "Compare with the generated preview")
        }
    }
    private struct PickButton: View {
        var studio: Studio
        var body: some View {
            Button {
                if let id = studio.activeTrialID { studio.toggleFavourite(id) }
            } label: { Image(systemName: studio.activeTrialID.map { studio.favouriteTrials.contains($0) } == true ? "star.fill" : "star") }
                .accessibilityLabel("Pick this preview").help("Include this preview when exporting picks")
        }
    }
    private struct ExportButton: View {
        var studio: Studio
        var body: some View {
            Button { studio.export() } label: {
                Image(systemName: "square.and.arrow.up").offset(y: -1)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(accent)
            .disabled(studio.exporting).accessibilityLabel("Export PNG").help("Export PNG (⌘E)")
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
