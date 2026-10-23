import CamiTuneDomain
import Combine
import SwiftUI

struct MeterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let rms: Double
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.1f dB", peak)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(x: normalized(rms), y: 1, anchor: .leading)
                        .animation(
                            reduceMotion ? nil : .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                            value: rms
                        )
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: geo.size.width * normalized(peak) - 1)
                        .animation(
                            reduceMotion ? nil : .linear(duration: UIRenderPerformance.animatedLevelTransitionDuration),
                            value: peak
                        )
                }
            }.frame(height: 9)
        }
    }

    private func normalized(_ db: Double) -> Double {
        min(1, max(0, (db + 72) / 72))
    }
}

struct SignalMetersView: View {
    let meters: AudioRuntimeMonitor
    let profile: DeviceProfile
    @State private var showAllChannels = false

    var body: some View {
        let layout = MultichannelMeterLayout(profile: profile)
        VStack(alignment: .leading, spacing: 12) {
            if layout.usesGroups {
                Toggle("Show All Channels", isOn: $showAllChannels)
                    .toggleStyle(.checkbox)
                if !showAllChannels {
                    Text("Group peak shows the loudest speaker; RMS shows average power.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ResponsiveStackLayout(minimumHorizontalWidth: 360, horizontalSpacing: 24) {
                meterGroup("Audio In", capture: true, layout: layout)
                meterGroup("Audio Out", capture: false, layout: layout)
            }
        }.onChange(of: profile.id) { _ in showAllChannels = false }
    }

    private func meterGroup(_ title: String, capture: Bool, layout: MultichannelMeterLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LiveChannelMeterBars(meters: meters, profileID: profile.id, capture: capture,
                rows: capture && layout.sourceChannels != nil ? layout.sourceChannels! : (layout.usesGroups && !showAllChannels ? layout.groups : layout.channels),
                requiresDSPCapture: layout.requiresDSPCapture)
        }.frame(maxWidth: .infinity)
    }
}

/// Keep live status observation local to the warning, just like the meter bars.
struct LiveClippingWarning: View {
    @ObservedObject var monitor: AudioRuntimeMonitor
    let profileID: UUID

    var body: some View {
        if monitor.activeSession?.profileID == profileID && monitor.status.clippingIsRecent {
            Label("DSP output clipping",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .help("DSP output clipping detected. Lower the preamp or enable the output limiter.")
                .accessibilityHint("Lower the preamp or enable the output limiter.")
        }
    }
}

struct MeterStatusDisclosure: View {
    let monitor: AudioRuntimeMonitor
    let profileID: UUID
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AudioRuntimeStatusView(monitor: monitor, profileID: profileID)
        } label: {
            Text("Status").font(.subheadline.weight(.semibold))
        }
        .disclosureGroupStyle(SectionDisclosureStyle())
        .onChange(of: profileID) { _ in isExpanded = false }
    }
}

private struct AudioRuntimeStatusView: View {
    @ObservedObject var monitor: AudioRuntimeMonitor
    let profileID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activeStatus.isActive && !activeStatus.pipelineAssessment().reasons.isEmpty {
                Text(activeStatus.pipelineAssessment().explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                latencySection
                processingSection
                signalSection
                deliverySection
            }
        }
    }

    private var latencySection: some View {
        let latency = activeStatus.addedDelayEstimate()
        return RuntimeStatusSection(title: "Latency") {
            RuntimeStatusRow(title: "Total", value: milliseconds(latency?.milliseconds))
            RuntimeStatusRow(title: "App transit", value: milliseconds(latency?.appMilliseconds))
            RuntimeStatusRow(title: "Processing buffer", value: milliseconds(latency?.processingMilliseconds))
            RuntimeStatusRow(title: "Playback buffer", value: milliseconds(latency?.playbackMilliseconds))
        }
    }

    private var processingSection: some View {
        RuntimeStatusSection(title: "Processing") {
            RuntimeStatusRow(title: "Buffer Size", value: telemetryIsFresh
                ? activeStatus.dspBlockFrames.map { "\($0) frames" } ?? "—" : "—")
            RuntimeStatusRow(title: "DSP load", value: telemetryIsFresh ? percent(activeStatus.processingLoadPercent) : "—")
            RuntimeStatusRow(title: "Resampler load", value: telemetryIsFresh ? percent(activeStatus.resamplerLoadPercent) : "—")
            RuntimeStatusRow(title: "DSP buffer", value: telemetryIsFresh ? "\(activeStatus.dspBufferLevelFrames) frames" : "—")
            RuntimeStatusRow(title: "Bridge buffer", value: activeStatus.route.bridgeFillRatio.map { percent($0 * 100) } ?? "—")
            RuntimeStatusRow(title: "Rate adjust", value: hasRoute || telemetryIsFresh
                ? String(format: "%+.1f ppm", activeStatus.effectiveRateAdjustmentPPM) : "—")
            RuntimeStatusRow(title: "Matched buffer", value: hasRoute ? "\(activeStatus.route.rateMatchBufferedFrames) frames" : "—")
        }
    }

    private var signalSection: some View {
        RuntimeStatusSection(title: "Signal") {
            RuntimeStatusRow(title: "Sample rate", value: hasRoute
                ? String(format: "%.1f kHz", activeStatus.route.sampleRate / 1_000) : "—")
            RuntimeStatusRow(title: "Channels", value: hasRoute ? "\(activeStatus.route.activeChannels)" : "—")
            RuntimeStatusRow(title: "DSP output clipping", value: clippingValue,
                accent: activeStatus.clippingIsRecent ? .red : nil)
            RuntimeStatusRow(title: "DSP clipped samples", value: telemetryIsFresh ? "\(activeStatus.dspClippedSamples)" : "—")
            RuntimeStatusRow(title: "Source samples at/above full scale", value: hasRoute ? "\(activeStatus.sourceClippedSamples)" : "—")
        }
    }

    private var deliverySection: some View {
        let route = activeStatus.route
        return RuntimeStatusSection(title: "Delivery") {
            RuntimeStatusRow(title: "Dropped frames", value: hasRoute
                ? "\(route.bridgeDroppedFrames + route.camillaDroppedFrames + route.rejectedSourceFrames)" : "—")
            RuntimeStatusRow(title: "Consumer overruns", value: hasRoute ? "\(route.bridgeConsumerOverrunCount)" : "—")
            RuntimeStatusRow(title: "Malformed recoveries", value: hasRoute ? "\(route.bridgeMalformedPacketCount)" : "—")
            RuntimeStatusRow(title: "Queue recoveries", value: hasRoute ? "\(route.camillaQueueRecoveries)" : "—")
        }
    }

    private var activeStatus: AudioRuntimeStatus {
        monitor.activeSession?.profileID == profileID ? monitor.status : .inactive
    }
    private var hasRoute: Bool { activeStatus.isActive && activeStatus.route.sampleRate > 0 }
    private var telemetryIsFresh: Bool { activeStatus.hasFreshTelemetry() }
    private var clippingValue: String {
        guard activeStatus.isActive else { return "—" }
        if activeStatus.clippingIsRecent { return "Detected recently" }
        return activeStatus.dspClippedSamples > 0 ? "Detected" : "None"
    }
    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }
    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
}

private struct RuntimeStatusSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold))
                Divider()
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct RuntimeStatusRow: View {
    let title: String
    let value: String
    var accent: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().foregroundStyle(accent ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct LiveChannelMeterBars: View {
    @ObservedObject var meters: AudioRuntimeMonitor
    let profileID: UUID
    let capture: Bool
    let rows: [MultichannelMeterLayout.Row]
    let requiresDSPCapture: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                let level = row.level(peak: peak, rms: rms, capture: capture)
                MeterBar(label: row.label, rms: level.rms, peak: level.peak)
            }
            if profileIsActive && capture && requiresDSPCapture && !meters.captureUsesDSPBus {
                Text("Input levels unavailable").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var profileIsActive: Bool { meters.activeSession?.profileID == profileID }
    private var levelsAvailable: Bool {
        profileIsActive && (!capture || !requiresDSPCapture || meters.captureUsesDSPBus)
    }
    private var rms: [Double] {
        guard levelsAvailable else { return [] }
        return capture ? meters.captureRMS : meters.playbackRMS
    }
    private var peak: [Double] {
        guard levelsAvailable else { return [] }
        return capture ? meters.capturePeak : meters.playbackPeak
    }
}
