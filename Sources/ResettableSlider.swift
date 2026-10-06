import SwiftUI
import AppKit

/// Keep AppKit's native tracking and keyboard behavior, intercepting only the
/// second mouse-down so a reset works on both the thumb and the track.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    var reset: () -> Void
    var small = false
    var fill: NSColor = .secondaryLabelColor
    var valueDescription: String?
    var help = "Double-click to reset"

    func makeNSView(context: Context) -> ResetSlider {
        let slider = ResetSlider()
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(ResetSlider.changed)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: ResetSlider, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.controlSize = small ? .small : .regular
        slider.trackFillColor = fill
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(valueDescription)
        slider.toolTip = help
        slider.onChange = { value = $0 }
        slider.onReset = reset
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResetSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 105, height: small ? 20 : 22)
    }
}

final class ResetSlider: NSSlider {
    var onChange: (Double) -> Void = { _ in }
    var onReset: () -> Void = {}
    @objc func changed() { onChange(doubleValue) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset() }
        else { super.mouseDown(with: event) }
    }
}
