import Combine
import SwiftUI

struct VerticalEQSlider: View {
    @Binding var gain: Double
    let audioDB: Double
    let responseDB: Double
    let gainEnabled: Bool
    var accessibilityTitle = "EQ band gain"
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }
    @State private var isDragging = false
    private let gainRange = -12.0...12.0
    private let visualizerRange = -72.0...0.0

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(x: (geometry.size.width - 7) / 2, y: 8, width: 7, height: geometry.size.height - 16)
            let preEQAmount = audioAmount(audioDB)
            let postEQAmount = audioAmount(audioDB + responseDB)
            let changeBottom = min(preEQAmount, postEQAmount)
            let changeHeight = track.height * abs(postEQAmount - preEQAmount)
            let thumbY = gainY(gain, track: track)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: 1, y: preEQAmount, anchor: .bottom)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.48), .green],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: 1, y: postEQAmount, anchor: .bottom)
                    .position(x: track.midX, y: track.midY)
                if changeHeight > 0.5 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(responseDB >= 0 ? Color.blue.opacity(0.88) : Color.orange.opacity(0.88))
                        .frame(width: track.width, height: max(2, changeHeight))
                        .position(
                            x: track.midX,
                            y: track.maxY - track.height * changeBottom - max(2, changeHeight) / 2
                        )
                }
                if abs(responseDB) >= 0.25, preEQAmount > 0 {
                    Capsule()
                        .fill(Color.primary.opacity(0.72))
                        .frame(width: 13, height: 1.5)
                        .position(x: track.midX, y: track.maxY - track.height * preEQAmount)
                }
                Circle()
                    .fill(gainEnabled ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.7))
                    .overlay(Circle().stroke(gainEnabled ? Color.primary.opacity(0.75) : Color.secondary, lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: track.midX, y: thumbY)
            }
            .animation(.easeOut(duration: 0.12), value: responseDB)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard gainEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let ratio = min(1, max(0, (value.location.y - track.minY) / track.height))
                        let raw = gainRange.upperBound - ratio * (gainRange.upperBound - gainRange.lowerBound)
                        let nextGain = (raw * 10).rounded() / 10
                        guard nextGain != gain else { return }
                        gain = nextGain
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("\(gain, format: .number.precision(.fractionLength(1))) decibels")
        .accessibilityAdjustableAction { direction in
            guard gainEnabled else { return }
            switch direction {
            case .increment: gain = min(gainRange.upperBound, gain + 0.1)
            case .decrement: gain = max(gainRange.lowerBound, gain - 0.1)
            @unknown default: break
            }
        }
    }

    private func audioAmount(_ db: Double) -> Double {
        min(1, max(0, (db - visualizerRange.lowerBound) /
            (visualizerRange.upperBound - visualizerRange.lowerBound)))
    }

    private func gainY(_ value: Double, track: CGRect) -> Double {
        let clamped = min(gainRange.upperBound, max(gainRange.lowerBound, value))
        let ratio = (gainRange.upperBound - clamped) / (gainRange.upperBound - gainRange.lowerBound)
        return track.minY + track.height * ratio
    }
}

struct EQGainGuideGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Content begins after the 8 pt outer padding and 24 pt
                // frequency row. The slider itself has an 8 pt inset.
                let sliderTop = 47.0
                let sliderBottom = 251.0
                let gridStartX = 44.0
                for db in stride(from: -12, through: 12, by: 3) {
                    let ratio = Double(12 - db) / 24.0
                    let yy = sliderTop + (sliderBottom - sliderTop) * ratio
                    var path = Path()
                    path.move(to: CGPoint(x: gridStartX, y: yy))
                    path.addLine(to: CGPoint(x: size.width, y: yy))
                    context.stroke(
                        path,
                        with: .color(Color.secondary.opacity(db == 0 ? 0.24 : 0.11)),
                        lineWidth: db == 0 ? 1 : 0.6
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct GainScaleLabels: View {
    var body: some View {
        GeometryReader { geometry in
            let top = 8.0
            let bottom = geometry.size.height - 8
            Text("+12")
                .position(x: geometry.size.width / 2, y: top)
            Text("0")
                .position(x: geometry.size.width / 2, y: (top + bottom) / 2)
            Text("−12")
                .position(x: geometry.size.width / 2, y: bottom)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

