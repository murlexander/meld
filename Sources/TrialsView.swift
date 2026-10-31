import SwiftUI
import AppKit

private typealias TrialState<Value> = SwiftUI.State<Value>

struct MaterialView: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Start with your material").font(.title2.weight(.medium))
            Text("Meld will turn your images into 36 possibilities.").foregroundStyle(.secondary)
            VStack(spacing: 16) {
                Button { studio.chooseSourceFolder() } label: {
                    Label(studio.sourceFolder?.lastPathComponent ?? "Choose source folder…", systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, minHeight: 24)
                }.modifier(StudioButtons()).controlSize(.large)
                    .help(studio.sourceFolder?.path ?? "Choose photos, textures, or RAW files")
                if studio.sourceFolder != nil {
                    Picker("Format", selection: $studio.batchAspect) {
                        Text("Square").tag("Square"); Text("Portrait").tag("Portrait"); Text("Landscape").tag("Landscape")
                    }.pickerStyle(.segmented).labelsHidden()
                    Button { studio.makeTrials() } label: {
                        Label("Generate 36 previews", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 28)
                    }.modifier(StudioButtons(prominent: true)).controlSize(.large)
                        .disabled(studio.materialsBusy || studio.makingTrials || studio.exportingTrials).keyboardShortcut(.defaultAction)
                }
                Text("Photos, textures and RAW. Subfolders included.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(width: 360)
            if studio.sourceScanning { ProgressView().controlSize(.small) }
            if !studio.trials.isEmpty {
                Button("Back to previews") { studio.showTrials() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)).navigationTitle("Meld")
    }
}

struct TrialsView: View {
    @ObservedObject var studio: Studio
    @TrialState private var columns = 4
    @FocusState private var gridFocused: Bool
    private var cellWidth: CGFloat { studio.thumbnailSize }
    private let spacing: CGFloat = 18, margin: CGFloat = 24
    var body: some View {
        VStack(spacing: 0) {
            Group {
                ScrollViewReader { proxy in
                    ScrollView {
                        if studio.visibleTrials.isEmpty { emptyState } else {
                            // Measure inside the scroll view so a visible scroller is excluded.
                            grid.background { GeometryReader { content in
                                Color.clear
                                    .onAppear { columns = columnCount(content.size.width) }
                                    .onChange(of: content.size.width) { _, width in columns = columnCount(width) }
                                    .onChange(of: studio.thumbnailSize) { _, _ in columns = columnCount(content.size.width) }
                            }}
                        }
                    }
                    .onChange(of: studio.gridSelection) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    .task {
                        // Wait for the first layout so the selected row exists before scrolling.
                        try? await Task.sleep(for: .milliseconds(30))
                        if let id = studio.gridSelection { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .focusable().focused($gridFocused).focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space]) { press in
                switch press.key {
                case .leftArrow: studio.moveSelection(by: -1)
                case .rightArrow: studio.moveSelection(by: 1)
                case .upArrow: studio.moveSelectionVertically(-1, columns: columns)
                case .downArrow: studio.moveSelectionVertically(1, columns: columns)
                default: if let id = studio.gridSelection { studio.openTrial(id) }
                }
                return .handled
            }
            // Louppe's culling keys: F picks, D removes the pick.
            // Russian-layout letters on the same keys (а, в, м) work too; Caps Lock is ignored.
            .onKeyPress(characters: CharacterSet(charactersIn: "fdvFDVавмАВМ=")) { press in
                if press.characters == "=" {
                    guard press.modifiers.subtracting(.capsLock) == .command else { return .ignored }
                    studio.zoomThumbnails(1); return .handled // ⌘= without Shift, as in Photos
                }
                guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty, let id = studio.gridSelection else { return .ignored }
                switch press.characters.lowercased() {
                case "f", "а": studio.setPick(id, true)
                case "d", "в": studio.setPick(id, false)
                default: if studio.canMakeVariations { studio.makeVariations(of: id) }
                }
                return .handled
            }
            .onAppear { gridFocused = true }
            Divider()
            HStack {
                Text("New sets keep your picks. Export them before closing Meld.")
                Spacer()
                Text("Double-click to refine · F to pick, D to unpick · V for variations · ⌘+ ⌘− to resize")
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor)).navigationTitle("")
            .toolbar { toolbar }
            .onChange(of: studio.groups.first?.id) { _, _ in if studio.makingTrials { studio.picksOnly = false } }
    }

    // The window toolbar owns navigation and actions, as in Louppe.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { studio.chooseMaterial() } label: {
                Label(studio.trialsFolder?.lastPathComponent ?? studio.sourceFolder?.lastPathComponent ?? "Source folder", systemImage: "folder")
                    .labelStyle(.titleAndIcon).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
            }
            .accessibilityLabel("Choose material")
            .help("Choose material for the next set · \(studio.trialsFolder?.path ?? studio.sourceFolder?.path ?? "No source folder")")
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { toolbarStatus }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { toolbarStatus }
        }
        ToolbarItemGroup {
            Toggle(isOn: $studio.picksOnly) {
                Image(systemName: studio.picksOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button).accessibilityLabel("Show picks only")
            .accessibilityValue("\(studio.favouriteTrials.count) picks")
            .help(studio.picksOnly ? "Show all previews" : "Show \(studio.favouriteTrials.count) picked previews")
            Button { if let id = studio.gridSelection { studio.makeVariations(of: id) } } label: {
                Image(systemName: "square.stack.3d.down.right")
            }
            .disabled(!studio.canMakeVariations).accessibilityLabel("Make 12 variations")
            .help("Make 12 variations of the selected preview (V)")
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            if studio.makingTrials {
                Button { studio.cancelTrials() } label: { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop generation").help("Stop and keep completed previews")
            } else {
                Button { studio.makeTrials() } label: { Image(systemName: "sparkles") }
                    .disabled(studio.sourceFolder == nil || studio.materialsBusy || studio.exportingTrials)
                    .accessibilityLabel("New 36 previews")
                    .help("Make a new set from the source folder; your picks stay (⌘R)")
            }
        }
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed) }
        ToolbarItem {
            if studio.exportingTrials {
                Button { studio.cancelTrialExport() } label: { Image(systemName: "stop.fill") }
                    .accessibilityLabel("Stop export").help("Stop and keep completed exports")
            } else {
                Button { studio.exportTrials() } label: {
                    Image(systemName: "square.and.arrow.up").offset(y: -1)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .disabled(studio.favouriteTrials.isEmpty || studio.makingTrials || studio.materialsBusy)
                .accessibilityLabel("Export picks").help("Export \(studio.favouriteTrials.count) picks as PNGs and a contact sheet")
            }
        }
    }

    private var toolbarStatus: some View {
        VStack(spacing: 2) {
            Text("\(studio.visibleTrials.count) previews · \(studio.favouriteTrials.count) picks")
                .monospacedDigit()
            HStack(spacing: 6) {
                if studio.makingTrials || studio.exportingTrials { ProgressView().controlSize(.mini) }
                Text(studio.exportingTrials
                     ? "Exporting \(studio.trialExportProgress) of \(studio.trialExportTotal)…"
                     : studio.trialMessage)
            }
        }.font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 320).help(studio.trialMessage)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if studio.makingTrials { ProgressView(); Text("Finding possibilities in your images…") }
            else if studio.picksOnly {
                Text("Star a preview to add it to your picks.")
                Button("Show all previews") { studio.picksOnly = false }.buttonStyle(.bordered)
            } else {
                Text("No previews yet.")
                Button("Choose material") { studio.chooseMaterial() }.buttonStyle(.bordered)
            }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 120)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(studio.groups) { group in
                let items = studio.visibleTrials.filter { $0.group == group.id }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if studio.groups.count > 1 {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(group.title).font(.headline)
                                Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: spacing)], spacing: 16) {
                            ForEach(items) { trial in cell(trial).id(trial.id) }
                        }
                    }
                }
            }
        }.padding(margin)
    }

    private func cell(_ trial: Trial) -> some View {
        let selected = studio.gridSelection == trial.id
        let picked = studio.favouriteTrials.contains(trial.id)
        return VStack(spacing: 8) {
            Image(decorative: trial.thumbnail, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity).frame(height: cellWidth - 12)
                .background(Color(nsColor: .controlBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { guard !studio.makingTrials else { return }; studio.openTrial(trial.id) }
                .simultaneousGesture(TapGesture().onEnded { studio.gridSelection = trial.id; gridFocused = true })
                .onDrag { studio.dragProvider(for: trial.id) }
                .accessibilityLabel("Preview \(trial.title)").accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                .accessibilityAction { studio.openTrial(trial.id) }
            HStack(spacing: 5) {
                Text(trial.title).font(.caption).foregroundStyle(selected ? .primary : .secondary)
                if trial.adjusted { Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.secondary).help("Adjusted") }
                Spacer(minLength: 0)
                Button { studio.toggleFavourite(trial.id) } label: {
                    Image(systemName: picked ? "star.fill" : "star")
                        .foregroundStyle(picked ? Color.accentColor : .secondary)
                }.buttonStyle(.plain).padding(3)
                    .accessibilityLabel("\(picked ? "Unpick" : "Pick") preview \(trial.number)")
            }.padding(.horizontal, 2)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay { if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .contextMenu {
            Button("Refine") { studio.openTrial(trial.id) }.disabled(studio.makingTrials)
            Button(picked ? "Remove from picks" : "Add to picks") { studio.toggleFavourite(trial.id) }
            Button("Make 12 variations") { studio.makeVariations(of: trial.id) }
                .disabled(studio.materialsBusy || studio.makingTrials || studio.exportingTrials)
            Divider()
            Button("Copy image") { studio.copyImage(of: trial.id) }.disabled(studio.copying)
        }
    }

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width - margin * 2 + spacing) / (cellWidth + spacing)))
    }
}
