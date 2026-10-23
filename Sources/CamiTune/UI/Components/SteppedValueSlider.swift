import AppKit
import SwiftUI

enum PreampSliderLayout {
    static let horizontalInset: CGFloat = 9
    static let totalHeight: CGFloat = 32
    static let trackHeight: CGFloat = 6
    static let labelY: CGFloat = 32
}

enum SliderThumbMetrics {
    static let thickness: CGFloat = 10
    static let length: CGFloat = 22

    static func size(vertical: Bool) -> CGSize {
        CGSize(width: vertical ? length : thickness, height: vertical ? thickness : length)
    }

    static func hitSize(vertical: Bool) -> CGSize {
        CGSize(width: vertical ? length : 12, height: vertical ? 12 : length)
    }
}

/// Settings-style handle artwork, independent of each slider's track and hit area.
struct SliderThumb: View {
    var axis: Axis = .horizontal
    var scale: CGFloat = 1
    var isEnabled = true
    var isPressed = false
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let enabled = isEnabled && environmentEnabled
        let emphasis = enabled ? 1.0 : 0.45
        RoundedRectangle(cornerRadius: SliderThumbArtwork.cornerRadius * scale, style: .continuous)
            .fill(LinearGradient(colors: [Color(nsColor: SliderThumbArtwork.topColor(enabled: enabled)),
                Color(nsColor: SliderThumbArtwork.bottomColor(enabled: enabled))], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: SliderThumbArtwork.cornerRadius * scale, style: .continuous)
                    .strokeBorder(Color.black.opacity((contrast == .increased ? 0.55 : 0.18) * emphasis), lineWidth: 0.5 * scale)
            }
            .frame(width: SliderThumbMetrics.size(vertical: axis == .vertical).width * scale,
                   height: SliderThumbMetrics.size(vertical: axis == .vertical).height * scale)
            .shadow(color: .black.opacity((isPressed ? 0.24 : 0.16) * emphasis), radius: scale, y: scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private enum SliderThumbArtwork {
    static let cornerRadius: CGFloat = 5
    // Disabled thumbs stay opaque so the track cannot show through the handle.
    static func topColor(enabled: Bool) -> NSColor {
        NSColor(calibratedWhite: enabled ? 1 : 0.92, alpha: 1)
    }
    static func bottomColor(enabled: Bool) -> NSColor {
        NSColor(calibratedWhite: enabled ? 0.94 : 0.90, alpha: 1)
    }
}

/// Enlarge the knob artwork and hit rectangle while keeping AppKit's track,
/// value positioning, focus, pointer tracking, keyboard and accessibility behavior.
private final class SettingsSliderCell: NSSliderCell {
    var usesPreampStyle = false

    override func barRect(flipped: Bool) -> NSRect {
        guard usesPreampStyle, let bounds = controlView?.bounds else {
            return super.barRect(flipped: flipped)
        }
        return NSRect(x: bounds.minX + PreampSliderLayout.horizontalInset,
                      y: bounds.midY - PreampSliderLayout.trackHeight / 2,
                      width: max(1, bounds.width - 2 * PreampSliderLayout.horizontalInset),
                      height: PreampSliderLayout.trackHeight)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let track = barRect(flipped: flipped)
        let size = SliderThumbMetrics.hitSize(vertical: isVertical)
        guard usesPreampStyle else {
            let native = super.knobRect(flipped: flipped)
            let center = NSPoint(x: isVertical ? track.midX : native.midX,
                                 y: isVertical ? native.midY : track.midY)
            let enlarged = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                  width: size.width, height: size.height)
            return native.union(enlarged)
        }
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        return NSRect(x: track.minX + track.width * fraction - size.width / 2,
                      y: track.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard usesPreampStyle else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let track = barRect(flipped: flipped)
        let path = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        NSColor.secondaryLabelColor.withAlphaComponent(0.18 * opacity).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.systemBlue.withAlphaComponent(opacity).setFill()
        NSRect(x: track.minX, y: track.minY,
               width: max(0, knobRect(flipped: flipped).midX - track.minX), height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        if minValue < 0, maxValue > 0 {
            let zeroX = track.minX + track.width * (-minValue / (maxValue - minValue))
            NSColor.secondaryLabelColor.withAlphaComponent(0.55 * opacity).setFill()
            NSRect(x: zeroX - 1, y: track.midY - 5.5, width: 2, height: 11).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let vertical = isVertical
        let track = barRect(flipped: controlView?.isFlipped ?? false)
        let size = SliderThumbMetrics.size(vertical: vertical)
        // AppKit's knob rectangle includes space for the old knob's shadow.
        // Preserve its value position, but center the artwork on the real bar.
        let center = NSPoint(x: vertical ? track.midX : knobRect.midX,
                             y: vertical ? knobRect.midY : track.midY)
        let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
            .insetBy(dx: usesPreampStyle ? 0 : 0.25, dy: usesPreampStyle ? 0 : 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: SliderThumbArtwork.cornerRadius,
                               yRadius: SliderThumbArtwork.cornerRadius)
        let opacity: CGFloat = isEnabled ? 1 : 0.45
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent((isHighlighted ? 0.24 : 0.16) * opacity)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSGradient(starting: SliderThumbArtwork.topColor(enabled: isEnabled),
                   ending: SliderThumbArtwork.bottomColor(enabled: isEnabled))?
            .draw(in: path, angle: controlView?.isFlipped == true ? 90 : -90)
        NSGraphicsContext.restoreGraphicsState()
        let borderOpacity: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.55 : 0.18
        NSColor.black.withAlphaComponent(borderOpacity * opacity).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// A native slider with optional precise steps and no expensive tick-mark tree.
/// Dragging, arrow keys, and accessibility adjustments use the same increment.
struct SteppedValueSlider: NSViewRepresentable {
    enum Style { case standard, preamp }

    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let style: Style
    var onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, style: Style = .standard,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.style = style
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Control {
        let slider = Control()
        slider.cell = SettingsSliderCell()
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }
    func updateNSView(_ slider: Control, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.increment = step ?? (range.upperBound - range.lowerBound) / 100
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        slider.isEnabled = context.environment.isEnabled
        slider.editingChanged = onEditingChanged
        if let cell = slider.cell as? SettingsSliderCell, cell.usesPreampStyle != (style == .preamp) {
            cell.usesPreampStyle = style == .preamp
            slider.invalidateIntrinsicContentSize()
        }
        slider.needsDisplay = true
        switch context.environment.controlSize {
        case .mini: slider.controlSize = .mini
        case .small: slider.controlSize = .small
        default: slider.controlSize = .regular
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100,
            height: style == .preamp ? PreampSliderLayout.totalHeight : nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: SteppedValueSlider
        init(_ parent: SteppedValueSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let rounded = parent.step.map { step in
                parent.range.lowerBound + ((slider.doubleValue - parent.range.lowerBound) / step).rounded() * step
            } ?? slider.doubleValue
            let next = min(parent.range.upperBound, max(parent.range.lowerBound, rounded))
            slider.doubleValue = next
            if parent.value != next { parent.value = next }
        }
    }

    final class Control: NSSlider {
        var increment = 1.0
        var editingChanged: (Bool) -> Void = { _ in }
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.height = max(size.height, SliderThumbMetrics.length + 2)
            return size
        }
        // The custom artwork is centered in its full 32-point frame. Native
        // slider insets would otherwise add eight points and shift it downward.
        override var alignmentRectInsets: NSEdgeInsets {
            (cell as? SettingsSliderCell)?.usesPreampStyle == true
                ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                : super.alignmentRectInsets
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            editingChanged(true)
            super.mouseDown(with: event)
            editingChanged(false)
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 124, 126: adjust(by: increment)
            case 123, 125: adjust(by: -increment)
            default: super.keyDown(with: event)
            }
        }
        override func accessibilityPerformIncrement() -> Bool { adjust(by: increment) }
        override func accessibilityPerformDecrement() -> Bool { adjust(by: -increment) }
        @discardableResult
        private func adjust(by amount: Double) -> Bool {
            guard isEnabled else { return false }
            editingChanged(true)
            doubleValue = min(maxValue, max(minValue, doubleValue + amount))
            if let action { sendAction(action, to: target) }
            editingChanged(false)
            return true
        }
    }
}
