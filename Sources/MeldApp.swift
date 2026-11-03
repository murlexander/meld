import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Explicit alias avoids the SDK's State macro with command-line toolchains.
private typealias AppState<Value> = SwiftUI.State<Value>

@main struct MeldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppState private var studio: Studio
    init() {
        if CommandLine.arguments.contains("--self-test") { SelfTest.run(); exit(0) }
        if CommandLine.arguments.contains("--benchmark") { Benchmark.run() }
        if CommandLine.arguments.contains("--ui-snapshot") { UISnapshot.run() }
        let isolated = CommandLine.arguments.contains("--ui-test")
        let model = Studio(restoreSource: !isolated, starter: false)
        if isolated, let i = CommandLine.arguments.firstIndex(of: "--ui-test-source"), i+1 < CommandLine.arguments.count {
            model.setSourceFolder(URL(fileURLWithPath: CommandLine.arguments[i+1]), scan: false)
        }
        _studio = AppState(initialValue: model)
    }
    var body: some Scene {
        Window("Meld", id: "studio") {
            StudioView(studio: studio)
        }.defaultSize(width: 1280, height: 820).windowStyle(.automatic).windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Choose material…") { studio.chooseMaterial() }.keyboardShortcut("n")
                    Button("Generate 36 previews") { studio.makeTrials() }.keyboardShortcut("r")
                        .disabled(studio.sourceFolder == nil || studio.materialsBusy || studio.makingTrials || studio.exportingTrials)
                    Button("Back to previews") { studio.showTrials() }.disabled(studio.trials.isEmpty)
                    Button("Make 12 Variations") {
                        if let id = studio.commandTarget { studio.makeVariations(of: id) }
                    }.keyboardShortcut("r", modifiers: [.command, .option])
                        .disabled(!studio.canMakeVariations)
                    Divider()
                    Button("Export picks…") { studio.exportTrials() }
                        .disabled(studio.favouriteTrials.isEmpty || studio.makingTrials || studio.exportingTrials)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Export PNG…") { studio.export() }.keyboardShortcut("e")
                        .disabled(studio.activeTrialID == nil || studio.exporting)
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    Button("Copy Image") { studio.copyImage() }.keyboardShortcut("c", modifiers: [.command, .shift])
                        .disabled(studio.commandTarget == nil || studio.copying)
                }
                CommandGroup(before: .toolbar) {
                    Button("Larger Thumbnails") { studio.zoomThumbnails(1) }.keyboardShortcut("+", modifiers: .command)
                        .disabled(studio.stage != .previews || studio.thumbnailSize == Studio.thumbnailSizes.last)
                    Button("Smaller Thumbnails") { studio.zoomThumbnails(-1) }.keyboardShortcut("-", modifiers: .command)
                        .disabled(studio.stage != .previews || studio.thumbnailSize == Studio.thumbnailSizes.first)
                    Divider()
                    ForEach(Array(Study.allCases.enumerated()), id: \.element) { index, study in
                        Toggle("\(study.rawValue) View", isOn: Binding(get: { studio.study == study }, set: { if $0 { studio.setStudy(study) } }))
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                            .disabled(studio.stage != .refine)
                    }
                    Divider()
                }
                CommandMenu("Preview") {
                    Button("Previous Preview") { studio.openAdjacentTrial(-1) }.keyboardShortcut("[", modifiers: .command)
                        .disabled(studio.stage != .refine || !studio.canOpenPrevious)
                    Button("Next Preview") { studio.openAdjacentTrial(1) }.keyboardShortcut("]", modifiers: .command)
                        .disabled(studio.stage != .refine || !studio.canOpenNext)
                    Divider()
                    Button(studio.commandTarget.map { studio.favouriteTrials.contains($0) } == true ? "Remove from Picks" : "Add to Picks") {
                        if let id = studio.commandTarget { studio.toggleFavourite(id) }
                    }.disabled(studio.commandTarget == nil)
                    Toggle("Show Picks Only", isOn: $studio.picksOnly).disabled(studio.trials.isEmpty)
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { studio.undo() }.keyboardShortcut("z").disabled(studio.stage != .refine || !studio.canUndo)
                    Button("Redo") { studio.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(studio.stage != .refine || !studio.canRedo)
                }
            }
    }
}
