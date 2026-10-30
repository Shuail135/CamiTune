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
                Toggle("Show All Output Channels", isOn: $showAllChannels)
                    .toggleStyle(.checkbox)
                if !showAllChannels {
                    Text("Output group peak shows the loudest speaker; RMS shows average power.")
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
                rows: capture ? layout.sourceChannels : (layout.usesGroups && !showAllChannels ? layout.groups : layout.channels))
        }.frame(maxWidth: .infinity)
    }
}

/// Keep live status observation local to the warning, just like the meter bars.
struct LiveClippingWarning: View {
    @ObservedObject var monitor: AudioRuntimeMonitor
    let profileID: UUID

    var body: some View {
        if monitor.activeSession?.profileID == profileID && monitor.status.clippingIsRecent {
            Label("Output clipping",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint("Reduce processing gain or check output protection.")
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
    let monitor: AudioRuntimeMonitor
    let profileID: UUID
    @State private var activeStatus = AudioRuntimeStatus.inactive

    var body: some View {
        AudioRuntimeStatusContent(activeStatus: activeStatus)
            // Meter samples must not rebuild the status text and layout. Only
            // telemetry or a session change affects this part of the panel.
            .onReceive(Publishers.CombineLatest(monitor.$activeSession, monitor.$status)
                .map { session, status in session?.profileID == profileID ? status : .inactive }
                .removeDuplicates()) { activeStatus = $0 }
    }
}

struct AudioRuntimeStatusContent: View {
    let activeStatus: AudioRuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if activeStatus.isActive && !activeStatus.pipelineAssessment().reasons.isEmpty {
                Text(activeStatus.pipelineAssessment().explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                processingSection
                latencySection
                signalSection
                deliverySection
            }
        }
    }

    private var latencySection: some View {
        let latency = activeStatus.latencyComponents()
        return RuntimeStatusSection(title: "Latency") {
            RuntimeStatusRow(title: "Total Latency", value: milliseconds(latency.estimate?.milliseconds))
            RuntimeStatusRow(title: "App transit", value: milliseconds(latency.appMilliseconds))
            RuntimeStatusRow(title: "Processing buffer", value: milliseconds(latency.processingMilliseconds))
            RuntimeStatusRow(title: "Output queue", value: milliseconds(latency.playbackMilliseconds))
        }
    }

    private var processingSection: some View {
        RuntimeStatusSection(title: "Audio Path") {
            RuntimeStatusRow(title: "Output engine", value: activeStatus.outputBackend)
            RuntimeStatusRow(title: "State", value: activeStatus.isActive ? (telemetryIsFresh ? activeStatus.engineState : "Waiting for status") : "Inactive")
            RuntimeStatusRow(title: "Output sample rate", value: telemetryIsFresh
                ? activeStatus.outputSampleRate.map { String(format: "%.1f kHz", $0 / 1_000) } ?? "—" : "—")
            RuntimeStatusRow(title: "Output block size", value: telemetryIsFresh
                ? activeStatus.outputBlockFrames.map { "\($0) samples" } ?? "—" : "—")
            if telemetryIsFresh, let load = activeStatus.processingLoadPercent {
                RuntimeStatusRow(title: "Engine load", value: percent(load))
            }
            if telemetryIsFresh, let load = activeStatus.resamplerLoadPercent {
                RuntimeStatusRow(title: "Resampler load", value: percent(load))
            }
            RuntimeStatusRow(title: "Rate adjust", value: hasRoute || telemetryIsFresh
                ? String(format: "%+.1f ppm", activeStatus.effectiveRateAdjustmentPPM) : "—")
        }
    }

    private var signalSection: some View {
        RuntimeStatusSection(title: "Signal") {
            RuntimeStatusRow(title: "Input sample rate", value: hasRoute
                ? String(format: "%.1f kHz", activeStatus.route.sampleRate / 1_000) : "—")
            RuntimeStatusRow(title: "Input channels", value: hasRoute ? "\(activeStatus.route.activeChannels)" : "—")
            RuntimeStatusRow(title: "Output clipping", value: clippingValue,
                accent: activeStatus.clippingIsRecent ? .red : nil)
            RuntimeStatusRow(title: "Output clipped samples", value: telemetryIsFresh ? "\(activeStatus.outputClippedSamples)" : "—")
            RuntimeStatusRow(title: "Source full-scale samples", value: hasRoute ? "\(activeStatus.sourceClippedSamples)" : "—")
        }
    }

    private var deliverySection: some View {
        let route = activeStatus.route
        return RuntimeStatusSection(title: "Delivery") {
            RuntimeStatusRow(title: "Output queue", value: telemetryIsFresh ? "\(activeStatus.outputBufferedFrames) frames" : "—")
            RuntimeStatusRow(title: "Bridge buffer", value: hasRoute ? route.bridgeFillRatio.map { percent($0 * 100) } ?? "—" : "—")
            if telemetryIsFresh, let underruns = activeStatus.outputUnderrunFrames {
                RuntimeStatusRow(title: "Output underrun frames", value: "\(underruns)", accent: underruns > 0 ? .orange : nil)
            }
            RuntimeStatusRow(title: "Dropped frames", value: hasRoute
                ? "\(route.bridgeDroppedFrames + route.camillaDroppedFrames + route.rejectedSourceFrames)" : "—")
            RuntimeStatusRow(title: "Consumer overruns", value: hasRoute ? "\(route.bridgeConsumerOverrunCount)" : "—")
            RuntimeStatusRow(title: "Malformed recoveries", value: hasRoute ? "\(route.bridgeMalformedPacketCount)" : "—")
            RuntimeStatusRow(title: "Queue recoveries", value: hasRoute ? "\(route.camillaQueueRecoveries)" : "—")
        }
    }

    private var hasRoute: Bool { activeStatus.isActive && activeStatus.route.sampleRate > 0 }
    private var telemetryIsFresh: Bool { activeStatus.hasFreshTelemetry() }
    private var clippingValue: String {
        guard activeStatus.isActive, telemetryIsFresh else { return "—" }
        if activeStatus.clippingIsRecent { return "Detected recently" }
        return activeStatus.outputClippedSamples > 0 ? "Detected" : "None"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                let level = row.level(peak: peak, rms: rms, capture: capture)
                MeterBar(label: row.label, rms: level.rms, peak: level.peak)
            }
        }
    }

    private var profileIsActive: Bool { meters.activeSession?.profileID == profileID }
    private var levelsAvailable: Bool {
        profileIsActive
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
