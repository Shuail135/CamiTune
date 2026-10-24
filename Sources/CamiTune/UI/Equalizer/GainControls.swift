import CamiTuneDomain
import Combine
import SwiftUI

struct PreampGainControl: View {
    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var delayValueWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .caption) private var statusWidth: CGFloat = 38
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var gainDB: Double
    @Binding var limiterEnabled: Bool
    let meters: AudioRuntimeMonitor
    let profileID: UUID
    var title = "User preamp"
    var channelIndex: Int?
    var channelIndices: [Int]?
    var visualEffectsEnabled = true
    var delayMilliseconds: Binding<Double>? = nil
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        GainControlLayout {
            Text(title).fixedSize()
            slider
                .uiInteractionAnchor("gain-slider-\(title)")
            valueField
            limiterControl
            limiterStatus
            if let delayMilliseconds {
                Text("Channel delay").fixedSize()
                ChannelDelaySlider(value: delayMilliseconds, onEditingChanged: onEditingChanged)
                    .uiInteractionAnchor("channel-delay-slider")
                HStack(spacing: 10) {
                    TextField("Channel delay", value: delayMilliseconds,
                        format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: delayValueWidth)
                        .accessibilityLabel("Channel delay in milliseconds")
                    Text("ms").foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var meterContext: GainMeterContext {
        .init(profileID: profileID, channelIndex: channelIndex, channelIndices: channelIndices,
            visualEffectsEnabled: visualEffectsEnabled)
    }

    private var slider: some View {
        LiveGainPresentation(meters: meters, context: meterContext, limiterEnabled: limiterEnabled) { reading in
            MeteredGainSlider(gainDB: $gainDB, totalPeakDB: reading.peak, isClipping: reading.clipping,
                animationsEnabled: visualEffectsEnabled, accessibilityTitle: title,
                onEditingChanged: onEditingChanged)
        }
    }

    private var valueField: some View {
        HStack(spacing: 10) {
            TextField(title, value: Binding(
                get: { gainDB },
                set: { gainDB = min(12, max(-12, $0)) }
            ), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: delayMilliseconds == nil ? valueWidth : delayValueWidth)
            Text("dB").foregroundStyle(.secondary).fixedSize()
        }
    }

    private var limiterControl: some View {
        Toggle("Limiter", isOn: $limiterEnabled)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    private var limiterStatus: some View {
        LiveGainPresentation(meters: meters, context: meterContext, limiterEnabled: limiterEnabled) { reading in
            Text("LIMIT")
                .font(.caption.bold())
                .foregroundStyle(Color.orange)
                .opacity(reading.atCeiling && !reading.clipping ? 1 : 0)
                .accessibilityHidden(!reading.atCeiling || reading.clipping)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: reading.atCeiling && !reading.clipping)
        }
        .frame(width: statusWidth, alignment: .leading)
    }
}

private struct GainMeterReading {
    var peak: Double = -150
    var clipping = false
    var atCeiling = false
}

private struct GainMeterContext {
    let profileID: UUID
    let channelIndex: Int?
    let channelIndices: [Int]?
    let visualEffectsEnabled: Bool

    @MainActor
    func reading(from meters: AudioRuntimeMonitor, limiterEnabled: Bool) -> GainMeterReading {
        guard visualEffectsEnabled, meters.activeSession?.profileID == profileID else { return .init() }
        let indices = channelIndices ?? channelIndex.map { [$0] }
        let peak: Double
        let clipping: Bool
        if let indices {
            peak = indices.compactMap { meters.playbackPeak.indices.contains($0) ? meters.playbackPeak[$0] : nil }.max() ?? -150
            clipping = indices.contains { meters.channelClippingIsRecent($0) }
        } else {
            peak = meters.playbackPeak.max() ?? -150
            clipping = meters.status.clippingIsRecent
        }
        return .init(peak: peak, clipping: clipping,
            atCeiling: limiterEnabled && peak >= LimiterProcessor.standard.clipLimitDB - 0.05)
    }
}

/// Only the level artwork and status observe telemetry. Text fields, toggles,
/// and the adaptive control layout remain untouched by audio publications.
private struct LiveGainPresentation<Content: View>: View {
    @ObservedObject var meters: AudioRuntimeMonitor
    let context: GainMeterContext
    let limiterEnabled: Bool
    @ViewBuilder var content: (GainMeterReading) -> Content
    var body: some View { content(context.reading(from: meters, limiterEnabled: limiterEnabled)) }
}

/// Repositions the same controls without rebuilding native fields. An optional
/// delay row shares the gain row's label, slider, and value columns.
private struct GainControlLayout: Layout {
    struct Cache { var sizes: [CGSize] }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(width: proposal.width, sizes: cache.sizes).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(width: bounds.width, sizes: cache.sizes)
        for (index, view) in subviews.enumerated() {
            let frame = result.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width proposedWidth: CGFloat?, sizes: [CGSize]) -> (size: CGSize, frames: [CGRect]) {
        if sizes.count == 8 {
            var columns = Array(sizes.prefix(5))
            columns[0].width = max(columns[0].width, sizes[5].width)
            columns[2].width = max(columns[2].width, sizes[7].width)
            let gain = arrangement(width: proposedWidth, sizes: columns)
            let top = gain.size.height + 12
            let inline = gain.frames[1].minY < gain.frames[0].maxY
            let labelHeight = max(sizes[5].height, sizes[7].height)
            let rowHeight = inline ? max(PreampSliderLayout.totalHeight, labelHeight) : labelHeight
            let sliderY = inline ? top + (rowHeight - PreampSliderLayout.totalHeight) / 2 : top + rowHeight + 6
            let delayFrames = [
                CGRect(x: gain.frames[0].minX, y: top + (rowHeight - sizes[5].height) / 2,
                    width: columns[0].width, height: sizes[5].height),
                CGRect(x: gain.frames[1].minX, y: sliderY,
                    width: gain.frames[1].width, height: PreampSliderLayout.totalHeight),
                CGRect(x: gain.frames[2].minX, y: top + (rowHeight - sizes[7].height) / 2,
                    width: columns[2].width, height: sizes[7].height)
            ]
            return (CGSize(width: gain.size.width, height: max(top + rowHeight, sliderY + PreampSliderLayout.totalHeight)),
                    gain.frames + delayFrames)
        }
        guard sizes.count == 5 else { return (.zero, []) }
        let labels = [0, 2, 3, 4]
        let labelWidth = labels.reduce(CGFloat.zero) { $0 + sizes[$1].width }
        let finiteWidth = proposedWidth.flatMap { $0.isFinite ? $0 : nil }
        let width = max(finiteWidth ?? labelWidth + 480, labels.map { sizes[$0].width }.max() ?? 0)
        var frames = [CGRect](repeating: .zero, count: 5)
        if width >= labelWidth + 180 {
            let height = max(32, sizes.map(\.height).max() ?? 0)
            var x: CGFloat = 0
            for index in sizes.indices {
                let size = index == 1 ? CGSize(width: min(440, width - labelWidth - 40), height: 32) : sizes[index]
                frames[index] = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
                x += size.width + 10
            }
            return (CGSize(width: width, height: height), frames)
        }
        let rows = width >= labelWidth + 30 ? [labels] : [[0, 2], [3, 4]]
        var y: CGFloat = 0
        for row in rows {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in row {
                let size = sizes[index]
                frames[index] = CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)
                x += size.width + 10
            }
            y += height + 6
        }
        frames[1] = CGRect(x: 0, y: y, width: width, height: 32)
        return (CGSize(width: width, height: y + 32), frames)
    }
}

private struct MeteredGainSlider: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                y: (PreampSliderLayout.totalHeight - PreampSliderLayout.trackHeight) / 2,
                width: max(1, geometry.size.width - 2 * PreampSliderLayout.horizontalInset),
                height: PreampSliderLayout.trackHeight
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
                    .animation(animationsEnabled && !reduceMotion
                        ? .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration) : nil,
                        value: totalPeakDB)
                Rectangle()
                    .fill(isClipping ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 2, height: 11)
                    .position(x: track.midX, y: track.midY)
                SliderThumb(isPressed: isDragging)
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
        return .blue
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
            SteppedValueSlider(value: Binding(
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

/// Pure SwiftUI delay control. The native macOS Slider inherited system accent
/// rendering (which can produce the black track seen in the screenshot) and its
/// AppKit tracking could compete with the page ScrollView. This control owns its
/// hit-testing and uses a high-priority horizontal drag instead.
private struct ChannelDelaySlider: View {
    @Binding var value: Double
    let onEditingChanged: @MainActor (Bool) -> Void
    @State private var isDragging = false

    private let range = 0.0...100.0
    private let step = 0.01
    private let inset = PreampSliderLayout.horizontalInset

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(
                x: inset,
                y: (geometry.size.height - PreampSliderLayout.trackHeight) / 2,
                width: max(1, geometry.size.width - 2 * inset),
                height: PreampSliderLayout.trackHeight
            )
            let amount = normalized(value)
            let thumbX = track.minX + track.width * amount

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: track.width, height: track.height)
                    .position(x: track.midX, y: track.midY)

                Capsule()
                    .fill(Color.blue.opacity(0.9))
                    .frame(width: track.width, height: track.height)
                    .scaleEffect(x: amount, y: 1, anchor: .leading)
                    .position(x: track.midX, y: track.midY)

                SliderThumb(isPressed: isDragging)
                    .position(x: thumbX, y: track.midY)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        setValue(forX: gesture.location.x, track: track)
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
        .accessibilityLabel("Channel delay")
        .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(2)))) milliseconds")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = quantized(min(range.upperBound, value + step))
            case .decrement: value = quantized(max(range.lowerBound, value - step))
            @unknown default: break
            }
        }
    }

    private func normalized(_ current: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, current))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func setValue(forX x: CGFloat, track: CGRect) {
        let ratio = min(1, max(0, (x - track.minX) / track.width))
        let raw = range.lowerBound + Double(ratio) * (range.upperBound - range.lowerBound)
        let next = quantized(raw)
        guard next != value else { return }
        value = next
    }

    private func quantized(_ raw: Double) -> Double {
        (raw / step).rounded() * step
    }
}
