import AppKit
import SwiftUI

/// `Meld --ui-benchmark <source folder>` measures main-thread time for interface updates in an
/// offscreen window, like `--ui-snapshot`, without activating the app or moving focus. Each line
/// is the main thread's CPU time for one action and the interface update that follows it.
@MainActor
enum UIBenchmark {
    static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        return (user + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6) * 1000
    }

    static func run() {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-benchmark"), i + 1 < args.count else {
            fputs("usage: Meld --ui-benchmark <source folder>\n", stderr); exit(2)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(120)
            while !condition() && Date() < deadline { pump(0.005) }
        }
        let studio = Studio(restoreSource: false, starter: false)
        var seeds = RecipeRandom(seed: 1)
        studio.nextSeed = { seeds.next() }
        studio.pasteboard = NSPasteboard(name: NSPasteboard.Name("studio.meld.ui-benchmark"))
        studio.setSourceFolder(URL(fileURLWithPath: args[i + 1], isDirectory: true), scan: false)
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: StudioView(studio: studio))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = host
        window.setFrame(CGRect(x: -30000, y: -30000, width: 1280, height: 820), display: false)
        window.orderBack(nil)
        pump(0.5)
        func measure(_ label: String, repeats: Int = 1, settle: TimeInterval = 0.03, _ action: (Int) -> Void) {
            var total = 0.0
            for r in 0..<repeats {
                let start = mainThreadCPU()
                action(r); pump(settle)
                total += mainThreadCPU() - start
            }
            print(String(format: "%@: %.1f ms", label, total / Double(repeats)))
        }
        measure("36 previews, whole set", settle: 0.2) { _ in studio.makeTrials(); wait { !studio.makingTrials } }
        measure("pick", repeats: 20) { r in studio.toggleFavourite(studio.trials[r].id) }
        measure("arrow key", repeats: 20) { _ in studio.moveSelection(by: 1) }
        measure("12 variations, whole row", settle: 0.2) { _ in studio.makeVariations(of: studio.trials[0].id); wait { !studio.makingTrials } }
        measure("open preview", settle: 0.2) { _ in studio.openTrial(studio.orderedTrials[0].id); wait { !studio.rendering } }
        measure("slider tick (90 at 60 Hz)", repeats: 90, settle: 0.016) { r in studio.setRefinement("colour", value: 0.5 + Double(r % 30) / 30) }
        wait { !studio.rendering }
        measure("next preview", repeats: 6, settle: 0.05) { _ in studio.openAdjacentTrial(1); wait { !studio.rendering } }
        measure("back to previews", settle: 0.3) { _ in studio.showTrials() }
        window.close()
        exit(0)
    }
}
