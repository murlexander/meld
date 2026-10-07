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
    @TrialState private var favouritesOnly = false
    private var visible: [Trial] {
        favouritesOnly ? studio.trials.filter { studio.favouriteTrials.contains($0.id) } : studio.trials
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { studio.chooseMaterial() } label: {
                    Label(studio.trialsFolder?.lastPathComponent ?? studio.sourceFolder?.lastPathComponent ?? "Source folder", systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }.modifier(StudioButtons()).help("Choose material for the next set")
                Spacer(minLength: 12)
                Toggle(isOn: $favouritesOnly) { Label("Picks \(studio.favouriteTrials.count)", systemImage: "star") }
                    .toggleStyle(.button).accessibilityLabel("Show picks")
                if studio.makingTrials {
                    ProgressView().controlSize(.small)
                    Button("Stop") { studio.cancelTrials() }
                } else if studio.exportingTrials {
                    ProgressView().controlSize(.small)
                    Button("Stop export") { studio.cancelTrialExport() }
                } else {
                    Button("New 36 previews") { studio.makeTrials() }
                        .disabled(studio.sourceFolder == nil || studio.materialsBusy)
                        .help("Replace this set; export your picks first")
                    Button("Export picks…") { studio.exportTrials() }
                        .modifier(StudioButtons(prominent: true)).disabled(studio.favouriteTrials.isEmpty)
                }
            }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
            HStack {
                Text(studio.exportingTrials ? "Exporting \(studio.trialExportProgress) of \(studio.trialExportTotal)…" : studio.trialMessage)
                    .lineLimit(1)
                Spacer()
                Text(studio.makingTrials ? "Refine when ready, or stop to explore these previews." : "Click to refine. Star the ones you like.")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            ScrollView {
                if visible.isEmpty {
                    VStack(spacing: 14) {
                        if studio.makingTrials { ProgressView(); Text("Finding possibilities in your images…") }
                        else if favouritesOnly {
                            Text("Star a preview to add it to your picks.")
                            Button("Show all previews") { favouritesOnly = false }.buttonStyle(.bordered)
                        } else {
                            Text("No previews yet.")
                            Button("Choose material") { studio.chooseMaterial() }.buttonStyle(.bordered)
                        }
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                        ForEach(visible) { trial in
                            VStack(spacing: 8) {
                                Button { studio.openTrial(trial.id) } label: {
                                    Image(decorative: trial.thumbnail, scale: 1).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity).frame(height: 158)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                }.buttonStyle(.plain).disabled(studio.makingTrials)
                                    .accessibilityLabel("Refine preview \(trial.title)")
                                HStack(spacing: 5) {
                                    Text(trial.title).font(.caption).foregroundStyle(.secondary)
                                    if trial.adjusted { Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.secondary).help("Adjusted") }
                                    Spacer(minLength: 0)
                                    Button { studio.toggleFavourite(trial.id) } label: {
                                        Image(systemName: studio.favouriteTrials.contains(trial.id) ? "star.fill" : "star")
                                            .foregroundStyle(studio.favouriteTrials.contains(trial.id) ? Color.accentColor : .secondary)
                                    }.buttonStyle(.plain).padding(3)
                                        .accessibilityLabel("\(studio.favouriteTrials.contains(trial.id) ? "Unpick" : "Pick") preview \(trial.number)")
                                }.padding(.horizontal, 2)
                            }
                        }
                    }.padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text("Export your picks before starting a new set or closing Meld.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }.background(Color(nsColor: .windowBackgroundColor)).navigationTitle("Meld")
            .onChange(of: studio.trials.first?.id) { _, _ in favouritesOnly = false }
    }
}
