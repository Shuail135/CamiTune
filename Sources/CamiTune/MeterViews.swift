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
    let profileID: UUID

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                meterGroup("Audio In", source: .capture)
                meterGroup("Audio Out", source: .playback)
            }
            VStack(alignment: .leading, spacing: 16) {
                meterGroup("Audio In", source: .capture)
                meterGroup("Audio Out", source: .playback)
            }
        }
    }

    private func meterGroup(_ title: String, source: LiveStereoMeterBars.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LiveStereoMeterBars(meters: meters, profileID: profileID, source: source)
        }.frame(maxWidth: .infinity)
    }
}

struct AudioRuntimeStatusView: View {
    @ObservedObject var monitor: AudioRuntimeMonitor
    let profileID: UUID

    private let columns = [
        GridItem(.adaptive(minimum: 170), spacing: 24)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 7, height: 7)
                Text(activeStatus.engineState)
                    .font(.body.weight(.medium))
                if activeStatus.stopReason != "None" {
                    Text(activeStatus.stopReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                RuntimeMetricValue(
                    title: "DSP load",
                    value: percent(activeStatus.processingLoadPercent),
                    detail: "Resampler \(percent(activeStatus.resamplerLoadPercent))"
                )
                RuntimeMetricValue(
                    title: "DSP buffer",
                    value: "\(activeStatus.dspBufferLevelFrames) frames",
                    detail: bridgeBufferDetail
                )
                RuntimeMetricValue(
                    title: "Rate adjust",
                    value: String(format: "%+.1f ppm", activeStatus.effectiveRateAdjustmentPPM),
                    detail: "Matched buffer \(activeStatus.route.rateMatchBufferedFrames) frames"
                )
                RuntimeMetricValue(
                    title: "Clipping",
                    value: clippingValue,
                    detail: clippingDetail,
                    accent: activeStatus.clippingIsRecent ? .red : nil
                )
                RuntimeMetricValue(
                    title: "Stream",
                    value: routeValue,
                    detail: activeStatus.route.sampleRate > 0 ? "System Audio Bridge" : "No active route"
                )
                RuntimeMetricValue(
                    title: "Delivery",
                    value: deliveryValue,
                    detail: deliveryDetail
                )
            }
        }
    }

    private var profileIsActive: Bool { monitor.activeSession?.profileID == profileID }
    private var activeStatus: AudioRuntimeStatus {
        profileIsActive ? monitor.status : .inactive
    }

    private var healthColor: Color {
        switch activeStatus.health {
        case .inactive: return .secondary
        case .healthy: return .green
        case .warning: return .orange
        case .fault: return .red
        }
    }

    private var bridgeBufferDetail: String {
        guard let ratio = activeStatus.route.bridgeFillRatio else {
            return "Bridge buffer unavailable"
        }
        return "Bridge \(Int((ratio * 100).rounded()))% full"
    }

    private var clippingValue: String {
        let hasClipping = activeStatus.dspClippedSamples > 0
            || activeStatus.sourceClippedSamples > 0
        return hasClipping ? "Detected" : "None"
    }

    private var clippingDetail: String {
        if activeStatus.clippingIsRecent { return "Detected recently" }
        return "DSP \(activeStatus.dspClippedSamples) · source \(activeStatus.sourceClippedSamples) samples"
    }

    private var routeValue: String {
        let route = activeStatus.route
        guard route.sampleRate > 0 else { return "Idle" }
        return String(format: "%.1f kHz · %u ch", route.sampleRate / 1_000, route.activeChannels)
    }

    private var deliveryValue: String {
        let route = activeStatus.route
        let dropped = route.bridgeDroppedFrames + route.camillaDroppedFrames
        return "\(dropped) dropped"
    }

    private var deliveryDetail: String {
        let route = activeStatus.route
        return "\(route.bridgeConsumerOverrunCount) consumer overruns · \(route.bridgeMalformedPacketCount) malformed recoveries · \(route.camillaQueueRecoveries) queue recoveries"
    }

    private func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
}

private struct RuntimeMetricValue: View {
    let title: String
    let value: String
    let detail: String
    var accent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(accent ?? .primary)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveStereoMeterBars: View {
    enum Source {
        case capture
        case playback
    }

    @ObservedObject var meters: AudioRuntimeMonitor
    let profileID: UUID
    let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeterBar(label: "L", rms: rms[safe: 0] ?? -150, peak: peak[safe: 0] ?? -150)
            MeterBar(label: "R", rms: rms[safe: 1] ?? -150, peak: peak[safe: 1] ?? -150)
        }
    }

    private var profileIsActive: Bool { meters.activeSession?.profileID == profileID }
    private var rms: [Double] {
        guard profileIsActive else { return [-150, -150] }
        return source == .capture ? meters.captureRMS : meters.playbackRMS
    }
    private var peak: [Double] {
        guard profileIsActive else { return [-150, -150] }
        return source == .capture ? meters.capturePeak : meters.playbackPeak
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
