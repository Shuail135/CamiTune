import Combine
import SwiftUI

struct VerticalEQSlider: View {
    var metrics = EQControlMetrics()
    @Binding var gain: Double
    let audioDB: Double
    let responseDB: Double
    let gainEnabled: Bool
    var accessibilityTitle = "EQ band gain"
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }
    var spectrum: SpectrumAnalyzer? = nil
    var profileID: UUID? = nil
    var frequency: Double = 1_000
    @State private var isDragging = false
    private let gainRange = -12.0...12.0

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(x: (geometry.size.width - 7 * metrics.scale) / 2, y: 8 * metrics.scale, width: 7 * metrics.scale, height: geometry.size.height - 16 * metrics.scale)
            let thumbY = gainY(gain, track: track)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Group {
                    if let spectrum, let profileID {
                        SpectrumBandLevelObserver(spectrum: spectrum, profileID: profileID, frequency: frequency) { level in
                            EQSliderMeterArtwork(track: track, audioDB: level, responseDB: responseDB)
                        }
                    } else {
                        EQSliderMeterArtwork(track: track, audioDB: audioDB, responseDB: responseDB)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                Circle()
                    .fill(gainEnabled ? Color(nsColor: .controlBackgroundColor) : Color.secondary.opacity(0.7))
                    .overlay(Circle().stroke(gainEnabled ? Color.primary.opacity(0.75) : Color.secondary, lineWidth: 1.5))
                    .frame(width: 17 * metrics.scale, height: 17 * metrics.scale)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: track.midX, y: thumbY)
            }
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

    private func gainY(_ value: Double, track: CGRect) -> Double {
        let clamped = min(gainRange.upperBound, max(gainRange.lowerBound, value))
        let ratio = (gainRange.upperBound - clamped) / (gainRange.upperBound - gainRange.lowerBound)
        return track.minY + track.height * ratio
    }
}

struct EQGainGuideGrid: View {
    var metrics = EQControlMetrics()
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Content begins after the 8 pt outer padding and 24 pt
                // frequency row. The slider itself has an 8 pt inset.
                let sliderTop = 47.0 * metrics.scale
                let sliderBottom = 251.0 * metrics.scale
                let gridStartX = 44.0 * metrics.scale
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
    var metrics = EQControlMetrics()
    var body: some View {
        GeometryReader { geometry in
            let top = 8.0 * metrics.scale
            let bottom = geometry.size.height - 8 * metrics.scale
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

private struct EQSliderMeterArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: CGRect
    let audioDB: Double
    let responseDB: Double
    var body: some View {
        let preEQAmount = min(1, max(0, (audioDB + 72) / 72))
        let postEQAmount = min(1, max(0, (audioDB + responseDB + 72) / 72))
        let changeBottom = min(preEQAmount, postEQAmount)
        let changeHeight = track.height * abs(postEQAmount - preEQAmount)
        ZStack {
            Capsule()
                .fill(Color.blue.opacity(0.18))
                .frame(width: track.width, height: track.height)
                .scaleEffect(x: 1, y: preEQAmount, anchor: .bottom)
                .position(x: track.midX, y: track.midY)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.48), .blue],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(width: track.width, height: track.height)
                .scaleEffect(x: 1, y: postEQAmount, anchor: .bottom)
                .position(x: track.midX, y: track.midY)
            if changeHeight > 0.5 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(responseDB >= 0 ? Color.green.opacity(0.88) : Color.orange.opacity(0.88))
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
        }
        .animation(reduceMotion ? nil : .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration), value: audioDB)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: responseDB)
        .allowsHitTesting(false)
    }
}
