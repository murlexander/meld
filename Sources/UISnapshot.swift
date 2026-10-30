import AppKit
import SwiftUI

/// `Meld --ui-snapshot <output> <source folder>` renders the real interface in an offscreen
/// window, without activating the app or moving focus, and writes one PNG per stage.
@MainActor
enum UISnapshot {
    static func run() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-snapshot"), i + 2 < args.count else {
            fputs("usage: Meld --ui-snapshot <output> <source folder>\n", stderr); exit(2)
        }
        let output = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let source = URL(fileURLWithPath: args[i + 2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(120)
            while !condition() && Date() < deadline { pump(0.01) }
        }
        let studio = Studio(restoreSource: false, starter: false)
        studio.pasteboard = NSPasteboard(name: NSPasteboard.Name("studio.meld.snapshot"))
        studio.setSourceFolder(source, scan: false)
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: StudioView(studio: studio).tint(.teal))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setFrame(CGRect(x: -30000, y: -30000, width: 1280, height: 820), display: false)
        window.orderBack(nil)
        func snap(_ name: String, appearance: NSAppearance.Name = .aqua) {
            window.appearance = NSAppearance(named: appearance)
            pump(0.6)
            let view = window.contentView!.superview ?? window.contentView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = output.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        snap("1-material")
        studio.makeTrials(); wait { !studio.makingTrials }
        guard studio.trials.count >= 10 else { fputs("The source folder produced too few previews\n", stderr); exit(1) }
        studio.toggleFavourite(studio.trials[2].id); studio.toggleFavourite(studio.trials[9].id)
        studio.makeTrials(); wait { !studio.makingTrials }
        studio.gridSelection = studio.orderedTrials[1].id
        snap("2-previews")
        studio.makeVariations(of: studio.orderedTrials[1].id); wait { !studio.makingTrials }
        studio.gridSelection = studio.orderedTrials[0].id
        snap("3-variations")
        snap("3-variations-dark", appearance: .darkAqua)
        studio.openTrial(studio.orderedTrials[0].id); wait { !studio.rendering }
        snap("4-refine")
        studio.setStudy(.notan); wait { !studio.rendering }
        snap("5-refine-notan")
        studio.setStudy(.colour); wait { !studio.rendering }
        snap("6-refine-dark", appearance: .darkAqua)
        window.close()
        exit(0)
    }
}
