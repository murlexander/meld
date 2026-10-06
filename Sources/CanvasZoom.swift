import SwiftUI

private typealias ZoomState<Value> = SwiftUI.State<Value>

// Like Louppe, percentages refer to image pixels per physical display pixel.
// Meld's image is its 2400-pixel export, independent of preview resolution.
enum CanvasZoomGeometry {
    static let outputEdge: CGFloat = 2400
    static let minimum: CGFloat = 0.05
    static let maximum: CGFloat = 4

    static func imageSize(ratio: CGFloat, displayScale: CGFloat) -> CGSize {
        let edge = outputEdge / max(1, displayScale)
        return ratio >= 1 ? CGSize(width: edge, height: edge / ratio)
            : CGSize(width: edge * ratio, height: edge)
    }
    static func fit(image: CGSize, viewport: CGSize) -> CGFloat {
        max(0.001, min(max(1, viewport.width - 24) / image.width,
                       max(1, viewport.height - 24) / image.height))
    }
    static func fraction(_ scale: CGFloat) -> Double {
        log(Double(min(maximum, max(minimum, scale)) / minimum)) / log(Double(maximum / minimum))
    }
    static func scale(_ fraction: Double) -> CGFloat {
        minimum * pow(maximum / minimum, min(1, max(0, fraction)))
    }
}

struct ZoomCanvas<Content: View>: View {
    var ratio: CGFloat
    var tint: Color
    var resolutionChanged: (Bool) -> Void
    @ViewBuilder var content: (CGSize) -> Content
    @Environment(\.displayScale) private var displayScale
    @ZoomState private var manualScale: CGFloat?
    @ZoomState private var pinchStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let base = CanvasZoomGeometry.imageSize(ratio: ratio, displayScale: displayScale)
            // Reserve only the compact control's height; artwork gets the remaining space.
            let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 48))
            let fitted = CanvasZoomGeometry.fit(image: base, viewport: viewport)
            let scale = manualScale ?? fitted
            let size = CGSize(width: base.width * scale, height: base.height * scale)
            VStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    content(size)
                        .frame(width: size.width, height: size.height)
                        .padding(12)
                        .frame(minWidth: viewport.width, minHeight: viewport.height)
                }
                .defaultScrollAnchor(.center)
                .frame(height: viewport.height)
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if pinchStart == nil { pinchStart = scale }
                    manualScale = min(CanvasZoomGeometry.maximum,
                                      max(CanvasZoomGeometry.minimum, (pinchStart ?? scale) * value.magnification))
                }.onEnded { _ in pinchStart = nil })
                zoomControl(scale: scale)
                    .frame(maxWidth: .infinity).frame(height: 48)
            }
        }
        .onChange(of: manualScale != nil) { _, manual in resolutionChanged(manual) }
    }

    private func zoomControl(scale: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button("Fit") { manualScale = nil }
                .buttonStyle(.borderless)
                .fontWeight(manualScale == nil ? .semibold : .regular)
                .foregroundStyle(manualScale == nil ? tint : .primary)
                .frame(width: 30, height: 24)
                .accessibilityLabel("Fit artwork in window")
                .accessibilityAddTraits(manualScale == nil ? .isSelected : [])
                .help("Fit artwork in window")
            ResettableSlider(value: Binding(get: { CanvasZoomGeometry.fraction(scale) },
                                  set: { manualScale = CanvasZoomGeometry.scale($0) }),
                             range: 0...1, label: "Canvas zoom", reset: { manualScale = nil },
                             small: true, fill: NSColor(tint),
                             valueDescription: "\(Int((scale * 100).rounded())) percent",
                             help: "Double-click to fit. Scroll to pan. At 100%, one export pixel fills one display pixel.")
                .frame(width: 105)
            Text("\(Int((scale * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(ZoomGlass())
    }
}

private struct ZoomGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
