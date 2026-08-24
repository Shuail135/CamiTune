import Combine
import SwiftUI

struct PreampGainControl: View {
    @Binding var gainDB: Double
    @Binding var limiterEnabled: Bool
    @ObservedObject var meters: AudioRuntimeMonitor
    let profileID: UUID
    var title = "User preamp"
    var channelIndex: Int?
    var visualEffectsEnabled = true
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .fixedSize()
            MeteredGainSlider(
                gainDB: $gainDB,
                totalPeakDB: totalPeakDB,
                isClipping: isClipping,
                animationsEnabled: visualEffectsEnabled,
                accessibilityTitle: title,
                onEditingChanged: onEditingChanged
            )
            .frame(minWidth: 140, idealWidth: 390, maxWidth: 440)
            TextField(title, value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            Text("dB")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            Toggle("Limiter", isOn: $limiterEnabled)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Hard-limit the final processed signal to −0.5 dBFS")
            if limiterEnabled {
                if isClipping {
                    Text("CLIP")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else if limiterAtCeiling {
                    Text("LIMIT")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: limiterEnabled && isClipping)
    }

    private var profileIsActive: Bool {
        meters.activeSession?.profileID == profileID
    }

    private var totalPeakDB: Double {
        guard visualEffectsEnabled, profileIsActive else { return -150 }
        if let channelIndex {
            return meters.playbackPeak.indices.contains(channelIndex)
                ? meters.playbackPeak[channelIndex]
                : -150
        }
        return meters.playbackPeak.max() ?? -150
    }

    private var isClipping: Bool {
        guard limiterEnabled, visualEffectsEnabled, profileIsActive else { return false }
        if let channelIndex {
            return meters.channelClippingIsRecent(channelIndex)
        }
        return meters.status.clippingIsRecent
    }

    private var limiterAtCeiling: Bool {
        profileIsActive
            && limiterEnabled
            && totalPeakDB >= LimiterProcessor.standard.clipLimitDB - 0.05
    }

}

private enum PreampSliderLayout {
    static let horizontalInset: CGFloat = 9
    static let controlHeight: CGFloat = 20
    static let totalHeight: CGFloat = 32
    static let labelY: CGFloat = 27
}

private struct MeteredGainSlider: View {
    @Binding var gainDB: Double
    let totalPeakDB: Double
    let isClipping: Bool
    let animationsEnabled: Bool
    let accessibilityTitle: String
    let onEditingChanged: @MainActor (Bool) -> Void
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(
                x: PreampSliderLayout.horizontalInset,
                y: (PreampSliderLayout.controlHeight - 7) / 2,
                width: max(1, geometry.size.width - 2 * PreampSliderLayout.horizontalInset),
                height: 7
            )
            let levelAmount = min(1, max(0, (totalPeakDB + 72) / 72))
            let thumbX = track.minX + track.width * ((gainDB + 12) / 24)
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)
                Capsule()
                    .fill(isClipping ? Color.red : levelColor)
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: levelAmount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)
                Rectangle()
                    .fill(isClipping ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 2, height: 11)
                    .position(x: track.midX, y: track.midY)
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .position(x: thumbX, y: track.midY)
                Group {
                    Text("−12")
                        .position(
                            x: track.minX,
                            y: PreampSliderLayout.labelY
                        )
                    Text("0")
                        .position(
                            x: track.midX,
                            y: PreampSliderLayout.labelY
                        )
                    Text("+12 dB")
                        .position(
                            x: track.maxX,
                            y: PreampSliderLayout.labelY
                        )
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.72))
                .allowsHitTesting(false)
            }
            .animation(
                animationsEnabled
                    ? .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration)
                    : nil,
                value: totalPeakDB
            )
            .animation(
                animationsEnabled ? .easeOut(duration: 0.1) : nil,
                value: isClipping
            )
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let ratio = min(1, max(0, (value.location.x - track.minX) / track.width))
                        let nextGain = ((-12 + ratio * 24) * 10).rounded() / 10
                        guard nextGain != gainDB else { return }
                        gainDB = nextGain
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: PreampSliderLayout.totalHeight)
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("\(gainDB, format: .number.precision(.fractionLength(1))) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gainDB = min(12, gainDB + 0.1)
            case .decrement: gainDB = max(-12, gainDB - 0.1)
            @unknown default: break
            }
        }
    }

    private var levelColor: Color {
        if totalPeakDB >= -3 { return .orange }
        return .green
    }
}

struct GainControl: View {
    @Binding var gainDB: Double
    let title: String
    var autoButtonTitle: String?
    var autoAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.body)
                .fixedSize()
            Slider(value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), in: -12...12, step: 0.1)
            .frame(minWidth: 140, idealWidth: 440, maxWidth: 440)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    Text("−12")
                    Spacer()
                    Text("0")
                    Spacer()
                    Text("+12 dB")
                }
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(0.72))
                .padding(.horizontal, 6)
                .offset(y: 8)
                .allowsHitTesting(false)
            }
            TextField(title, value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 58)
            Text("dB")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let autoButtonTitle, let autoAction {
                Button(autoButtonTitle, action: autoAction)
                    .fixedSize()
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
