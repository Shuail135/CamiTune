import Combine
import SwiftUI

struct SimpleEQControlsView: View {
    @Binding var bands: [EQBand]
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 24) {
            ForEach(SimpleEQRange.allCases) { range in
                SimpleEQKnob(
                    value: binding(for: range),
                    range: range,
                    isEnabled: SimpleEQControl.value(for: range, in: bands) != nil,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }

    private func binding(for range: SimpleEQRange) -> Binding<Double> {
        Binding(
            get: { SimpleEQControl.value(for: range, in: bands) ?? 0 },
            set: { bands = SimpleEQControl.setting($0, for: range, in: bands) }
        )
    }
}

private struct SimpleEQKnob: View {
    @Binding var value: Double
    let range: SimpleEQRange
    let isEnabled: Bool
    let onEditingChanged: @MainActor (Bool) -> Void
    @State private var dragOrigin: Double?

    private var normalizedValue: Double {
        let limits = SimpleEQControl.gainRange
        return (value - limits.lowerBound) / (limits.upperBound - limits.lowerBound)
    }

    private var angle: Angle {
        .degrees(-135 + min(1, max(0, normalizedValue)) * 270)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(range.title)
                .font(.headline)
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
                        if dragOrigin == nil {
                            dragOrigin = value
                            onEditingChanged(true)
                        }
                        let origin = dragOrigin ?? value
                        setValue(origin - Double(gesture.translation.height) * 0.08)
                    }
                    .onEnded { _ in
                        guard dragOrigin != nil else { return }
                        dragOrigin = nil
                        onEditingChanged(false)
                    }
            )
            .onTapGesture(count: 2) {
                guard isEnabled else { return }
                setValue(0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(range.title)
            .accessibilityValue(isEnabled ? formattedValue : "No matching bands")
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                switch direction {
                case .increment: setValue(value + SimpleEQControl.step)
                case .decrement: setValue(value - SimpleEQControl.step)
                @unknown default: break
                }
            }

            Text(isEnabled ? formattedValue : "—")
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text(range.frequencyDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 108)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var formattedValue: String {
        String(format: "%+.1f dB", value)
    }

    private func setValue(_ newValue: Double) {
        let limits = SimpleEQControl.gainRange
        let clamped = min(limits.upperBound, max(limits.lowerBound, newValue))
        value = (clamped / SimpleEQControl.step).rounded() * SimpleEQControl.step
    }
}
