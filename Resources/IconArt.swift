import AppKit
import SwiftUI

// Draws each disc of the app icon as a white shape on the full 1024-point
// Icon Composer canvas so the layers line up. Meld.icon gives each disc its own
// glass group and colour, and adds the background and appearances.
let canvas: CGFloat = 1024

struct Disc: View {
    let offset: CGSize
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 440, height: 440)
            .offset(offset)
            .frame(width: canvas, height: canvas)
    }
}

let layers: [(String, Disc)] = [
    ("teal", Disc(offset: CGSize(width: -120, height: 90))),
    ("coral", Disc(offset: CGSize(width: 120, height: 90))),
    ("gold", Disc(offset: CGSize(width: 0, height: -120))),
]

MainActor.assumeIsolated {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    for (name, view) in layers {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { fatalError("Could not render \(name)") }
        try! png.write(to: out.appendingPathComponent("\(name).png"))
    }
}
