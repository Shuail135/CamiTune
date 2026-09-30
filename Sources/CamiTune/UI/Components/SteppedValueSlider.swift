import AppKit
import SwiftUI

/// A native slider with precise numeric steps and no expensive tick-mark tree.
/// Dragging, arrow keys, and accessibility adjustments use the same increment.
struct SteppedValueSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Control {
        let slider = Control()
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
        slider.increment = step
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        slider.isEnabled = context.environment.isEnabled
        slider.editingChanged = onEditingChanged
        switch context.environment.controlSize {
        case .mini: slider.controlSize = .mini
        case .small: slider.controlSize = .small
        default: slider.controlSize = .regular
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100,
            height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: SteppedValueSlider
        init(_ parent: SteppedValueSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) {
            let rounded = parent.range.lowerBound + ((slider.doubleValue - parent.range.lowerBound) / parent.step).rounded() * parent.step
            let next = min(parent.range.upperBound, max(parent.range.lowerBound, rounded))
            slider.doubleValue = next
            if parent.value != next { parent.value = next }
        }
    }

    final class Control: NSSlider {
        var increment = 1.0
        var editingChanged: (Bool) -> Void = { _ in }
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
