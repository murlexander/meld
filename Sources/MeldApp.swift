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
        _studio = StateObject(wrappedValue: Studio(restoreSource: !CommandLine.arguments.contains("--ui-test")))
    }
    var body: some Scene {
        Window("Meld", id: "studio") {
            StudioView(studio: studio)
        }.defaultSize(width: 1280, height: 820).windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New blank canvas") { studio.newCanvas() }.keyboardShortcut("n")
                    Button("Add images…") { studio.importPanel() }.keyboardShortcut("i")
                    Button("Choose source folder…") { studio.chooseSourceFolder() }
                    Divider()
                    Button("Load colour study") { studio.loadStarter() }
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Export PNG…") { studio.export() }.keyboardShortcut("e").disabled(studio.exporting)
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Undo") { studio.undo() }.keyboardShortcut("z").disabled(!studio.canUndo)
                    Button("Redo") { studio.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!studio.canRedo)
                }
            }
    }
}
