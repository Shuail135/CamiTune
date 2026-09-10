import SwiftUI

@MainActor
struct PerChannelProcessingView: View {
    let state: AppState
    @Binding var profile: DeviceProfile

    @State var selectedChannelIndex = 0
    @State var pendingBandCount: Int?
    @State var showBandReductionConfirmation = false
    @StateObject var runtime = PerChannelEditorRuntime()
    @State var runtimeVisualsActive = false

    var profileIsActive: Bool {
        state.isActive && state.activeProfileID == profile.id
    }

    var editableChannels: [ChannelProcessing] {
        (0..<max(1, min(32, profile.processingChannelCount))).map { index in
            profile.processing.channels.first(where: { $0.index == index })
                ?? ChannelProcessing(index: index, role: profile.usesReferenceSpeakers
                    ? (profile.speakerTopology?.endpoints.first(where: { $0.id.channelIndex == index })?.role ?? .unknown)
                    : (index == 0 ? .left : .right))
        }
    }

    var selectedChannel: ChannelProcessing {
        editableChannels.first(where: { $0.index == selectedChannelIndex })
            ?? editableChannels[0]
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PerChannelHeader(
                    status: runtime.status,
                    onReset: resetSelectedChannel,
                    onSave: saveSelectedChannel
                )

                Text("Global processing runs first. These settings then affect only the selected physical channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Channel", selection: Binding(
                    get: { selectedChannelIndex },
                    set: { selectChannel($0) }
                )) {
                    ForEach(editableChannels) { channel in
                        Text("\(channel.role.shortName) · Ch \(channel.index)")
                            .tag(channel.index)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                HStack(spacing: 8) {
                    Text(selectedChannel.role.groupName)
                        .font(.headline)
                    Text("\(selectedChannel.role.displayName) (\(selectedChannel.role.shortName))")
                    Text("Channel \(selectedChannel.index)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                PerChannelGainRow(
                    gain: runtime.gain,
                    limiter: runtime.limiter,
                    meters: state.meters,
                    profileID: profile.id,
                    channelIndex: selectedChannelIndex,
                    visualEffectsEnabled: runtimeVisualsActive,
                    onChanged: channelSettingsChanged,
                    onEditingChanged: continuousEditingChanged
                )

                PerChannelDelayRow(
                    delay: runtime.delay,
                    onChanged: channelSettingsChanged,
                    onEditingChanged: continuousEditingChanged
                )

                Text("Use delay to time-align this channel. Fractional-sample values are supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PerChannelResponseGraph(responses: runtime.responses)

                PerChannelBandsSection(
                    bands: runtime.bands,
                    responses: runtime.responses,
                    requestBandCount: requestBandCount,
                    setKind: EQEditorSupport.setKind,
                    onBandChanged: channelSettingsChanged,
                    onGainEditingChanged: continuousEditingChanged
                )
            }
            .padding(6)
        }
        .alert("Recalculate Equalizer Bands?", isPresented: $showBandReductionConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingBandCount = nil
            }
            Button("Recalculate", role: .destructive) {
                applyPendingBandReduction()
            }
        } message: {
            Text(bandReductionConfirmationMessage)
        }
        .onAppear {
            runtimeVisualsActive = true
            loadSelectedChannelIfNeeded()
        }
        .onChange(of: profile.id) { _ in
            runtime.loadedProfileID = nil
            loadSelectedChannelIfNeeded()
        }
        .onChange(of: profile.sampleRate) { _ in updateResponses() }
        .onDisappear {
            runtimeVisualsActive = false
        }
    }
}

private struct PerChannelHeader: View {
    @ObservedObject var status: PerChannelStatusState
    let onReset: @MainActor () -> Void
    let onSave: @MainActor () -> Void

    var body: some View {
        HStack {
            Text("Per-channel EQ, Gain & Delay").font(.title3.bold())
            Text(status.isSaved ? "Saved" : "Not saved")
                .font(.caption.weight(.medium))
                .foregroundStyle(status.isSaved ? Color.green : Color.secondary)
            Spacer()
            Button("Reset channel") {
                onReset()
            }
            .disabled(!status.canReset)
            Button {
                onSave()
            } label: {
                Text("Save")
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PerChannelGainRow: View {
    @ObservedObject var gain: PerChannelValueState<Double>
    @ObservedObject var limiter: PerChannelValueState<Bool>
    let meters: AudioRuntimeMonitor
    let profileID: UUID
    let channelIndex: Int
    let visualEffectsEnabled: Bool
    let onChanged: @MainActor () -> Void
    let onEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        PreampGainControl(
            gainDB: Binding(
                get: { gain.value },
                set: { newValue in
                    let clamped = min(12, max(-12, newValue))
                    guard clamped != gain.value else { return }
                    gain.value = clamped
                    onChanged()
                }
            ),
            limiterEnabled: Binding(
                get: { limiter.value },
                set: { newValue in
                    guard newValue != limiter.value else { return }
                    limiter.value = newValue
                    onChanged()
                }
            ),
            meters: meters,
            profileID: profileID,
            title: "Channel gain",
            channelIndex: channelIndex,
            visualEffectsEnabled: visualEffectsEnabled,
            onEditingChanged: onEditingChanged
        )
    }
}

private struct PerChannelDelayRow: View {
    @ObservedObject var delay: PerChannelValueState<Double>
    let onChanged: @MainActor () -> Void
    let onEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Channel delay")
                .frame(width: 130, alignment: .leading)
            ChannelDelaySlider(
                value: Binding(
                    get: { delay.value },
                    set: { newValue in
                        let clamped = min(100, max(0, newValue))
                        guard clamped != delay.value else { return }
                        delay.value = clamped
                        onChanged()
                    }
                ),
                onEditingChanged: onEditingChanged
            )
            .frame(minWidth: 180, maxWidth: .infinity)
            Text(
                delay.value.formatted(
                    .number.precision(.fractionLength(2))
                ) + " ms"
            )
            .monospacedDigit()
            .frame(width: 76, alignment: .trailing)
        }
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
    private let inset: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let track = CGRect(
                x: inset,
                y: (geometry.size.height - 7) / 2,
                width: max(1, geometry.size.width - 2 * inset),
                height: 7
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

                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.75), lineWidth: 1.5))
                    .frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
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
        .frame(height: 24)
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

private struct PerChannelResponseGraph: View {
    @ObservedObject var responses: PerChannelResponseState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Combined channel response")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("gain + channel filters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LineGraph(
                points: responses.totalResponse.map { ($0.frequency, $0.gainDB) },
                xRange: 20...20_000,
                yRange: -24...24,
                zeroLine: true,
                lineColor: .blue
            )
            .frame(height: 120)
        }
    }
}

private struct PerChannelBandsSection: View {
    @ObservedObject var bands: PerChannelBandsState
    let responses: PerChannelResponseState
    let requestBandCount: @MainActor (Int) -> Void
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let onBandChanged: @MainActor () -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("EQ bands")
                Picker("EQ bands", selection: Binding(
                    get: { bands.count },
                    set: { requestBandCount($0) }
                )) {
                    ForEach(0...20, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 64)
            }

            if bands.isEmpty {
                HStack {
                    Text("No channel-specific filters. The channel gain still applies.")
                        .foregroundStyle(.secondary)
                    Button("Add 8 bands") { requestBandCount(8) }
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            } else {
                let columnWidth = 96.0
                let contentWidth = GraphicEqualizerBands.requiredContentWidth(
                    bandCount: bands.count,
                    columnWidth: columnWidth
                )
                OverflowAwareHorizontalScrollView(
                    contentWidth: contentWidth,
                    height: 402
                ) {
                    PerChannelGraphicEqualizerBands(
                        bands: bands,
                        responses: responses,
                        setKind: setKind,
                        columnWidth: columnWidth,
                        onBandChanged: onBandChanged,
                        onGainEditingChanged: onGainEditingChanged
                    )
                }
            }
        }
    }
}
