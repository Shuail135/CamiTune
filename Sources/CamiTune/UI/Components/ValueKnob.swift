import SwiftUI

struct ValueKnobRow<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 24
    @ScaledMetric(relativeTo: .body) var minimumHorizontalWidth: CGFloat = 372
    @ViewBuilder var content: Content

    var body: some View {
        ResponsiveStackLayout(minimumHorizontalWidth: minimumHorizontalWidth,
            horizontalSpacing: spacing, verticalSpacing: spacing, centered: true) { content }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
    }
}

/// The simple EQ and spatial controls share their artwork and editing behavior.
@MainActor
struct ValueKnob: View {
    @ScaledMetric(relativeTo: .body) private var columnWidth: CGFloat = 108
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let resetValue: Double
    let formattedValue: String
    var titleLines = 1
    var centersResetValue = false
    var help: String?
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }
    @State private var drag: DragState?

    private struct DragState {
        var value: Double
        var translation: Double = 0
    }

    private var angle: Angle {
        let center = centersResetValue ? resetValue : (range.lowerBound + range.upperBound) / 2
        let extent = max(center - range.lowerBound, range.upperBound - center)
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        // Keep the same scale on both sides; asymmetric limits stop at different angles.
        return .degrees((clamped - center) / extent * 135)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(titleLines, reservesSpace: true)
                    .multilineTextAlignment(.center)
                if let help {
                    DeviceCorrectionHelpIcon(title: title, message: help)
                }
            }
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 2.5, height: 14)
                    .offset(y: -14)
                    .rotationEffect(angle)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        var edit = drag ?? DragState(value: value)
                        if drag == nil { onEditingChanged(true) }
                        let translation = Double(gesture.translation.height)
                        let sensitivity = (range.upperBound - range.lowerBound) / 300
                        // Discard overshoot so reversing at a limit moves the knob immediately.
                        edit.value = min(range.upperBound, max(range.lowerBound,
                            edit.value + (edit.translation - translation) * sensitivity))
                        edit.translation = translation
                        drag = edit
                        setValue(edit.value)
                    }
                    .onEnded { _ in
                        guard drag != nil else { return }
                        drag = nil
                        onEditingChanged(false)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { editValue(resetValue) }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(formattedValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: editValue(value + step)
                case .decrement: editValue(value - step)
                @unknown default: break
                }
            }

            Text(formattedValue)
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
        .frame(width: columnWidth + (help == nil ? 0 : 26))
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func editValue(_ newValue: Double) {
        guard isEnabled else { return }
        // Discrete edits must finish the same save/undo transaction as a drag.
        let isDiscreteEdit = drag == nil
        if isDiscreteEdit { onEditingChanged(true) }
        setValue(newValue)
        if isDiscreteEdit { onEditingChanged(false) }
    }

    private func setValue(_ newValue: Double) {
        let clamped = min(range.upperBound, max(range.lowerBound, newValue))
        let rounded = (clamped / step).rounded() * step
        let next = min(range.upperBound, max(range.lowerBound, rounded))
        if value != next { value = next }
    }
}
