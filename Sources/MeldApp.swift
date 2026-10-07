import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct MeldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var studio: Studio
    init() {
        if CommandLine.arguments.contains("--self-test") { SelfTest.run(); exit(0) }
        let isolated = CommandLine.arguments.contains("--ui-test")
        let model = Studio(restoreSource: !isolated, starter: false)
        if isolated, let i = CommandLine.arguments.firstIndex(of: "--ui-test-source"), i+1 < CommandLine.arguments.count {
            model.setSourceFolder(URL(fileURLWithPath: CommandLine.arguments[i+1]), scan: false)
        }
        _studio = StateObject(wrappedValue: model)
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
                    Divider()
                    Button("Export picks…") { studio.exportTrials() }
                        .disabled(studio.favouriteTrials.isEmpty || studio.makingTrials || studio.exportingTrials)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Export PNG…") { studio.export() }.keyboardShortcut("e")
                        .disabled(studio.activeTrialID == nil || studio.exporting)
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { studio.undo() }.keyboardShortcut("z").disabled(studio.stage != .refine || !studio.canUndo)
                    Button("Redo") { studio.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(studio.stage != .refine || !studio.canRedo)
                }
            }
    }
}
