import CamiTuneDomain
import Combine
import SwiftUI

struct GraphicEqualizerBands: View {
    var metrics = EQControlMetrics()
    @Binding var bands: [EQBand]
    var spectrum: SpectrumAnalyzer? = nil
    let profileID: UUID
    let responsePoints: [EQResponsePoint]
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat
    var showsSpectrumLevels = true
    var onGainEditingChanged: @MainActor (Bool) -> Void = { _ in }

    static func requiredContentWidth(
        bandCount: Int,
        columnWidth: CGFloat,
        scale: CGFloat = 1
    ) -> CGFloat {
        // The HStack contains a 32 pt gain scale followed by one 5 pt
        // inter-item gap and one fixed-width column per band.
        32 * scale + CGFloat(max(0, bandCount)) * (columnWidth + 5 * scale)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5 * metrics.scale) {
            VStack(spacing: 7 * metrics.scale) {
                Text("dB")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24 * metrics.scale)
                GainScaleLabels()
                    .frame(width: 32 * metrics.scale, height: metrics.sliderHeight)
            }
            .frame(width: 32 * metrics.scale)

            ForEach(bands) { band in
                EQBandColumn(
                    band: binding(for: band),
                    audioDB: -100,
                    responseDB: responseGain(at: band.frequency),
                    setKind: setKind,
                    commitFrequency: { frequency in
                        commitFrequency(frequency, for: band.id)
                    },
                    onGainEditingChanged: onGainEditingChanged,
                    spectrum: showsSpectrumLevels ? spectrum : nil,
                    profileID: profileID
                )
                .frame(width: columnWidth)
            }
        }
        .padding(.vertical, 8 * metrics.scale)
        .background(alignment: .topLeading) {
            EQGainGuideGrid()
        }
    }

    private func responseGain(at frequency: Double) -> Double {
        guard !responsePoints.isEmpty else { return 0 }
        var lower = 0
        var upper = responsePoints.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if responsePoints[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return responsePoints[0].gainDB }
        if lower == responsePoints.count { return responsePoints[lower - 1].gainDB }
        let before = responsePoints[lower - 1]
        let after = responsePoints[lower]
        return logDistance(before.frequency, frequency) <= logDistance(after.frequency, frequency)
            ? before.gainDB
            : after.gainDB
    }

    /// SwiftUI's collection bindings are index-backed on macOS 13. A row can be
    /// evaluated once more after the collection becomes empty, so resolve every
    /// read and write by stable band identity and safely ignore a removed row.
    private func binding(for snapshot: EQBand) -> Binding<EQBand> {
        Binding(
            get: {
                bands.first(where: { $0.id == snapshot.id }) ?? snapshot
            },
            set: { updated in
                guard let index = bands.firstIndex(where: { $0.id == snapshot.id }) else { return }
                // Gain/Q/type/enabled edits keep the existing column order. Frequency
                // changes are committed separately so selecting/editing the Hz field
                // cannot reorganize the band strip underneath the pointer.
                bands[index] = updated
            }
        )
    }

    private func commitFrequency(_ frequency: Double, for bandID: UUID) {
        guard frequency.isFinite, frequency > 0,
              let index = bands.firstIndex(where: { $0.id == bandID }) else { return }
        guard bands[index].frequency != frequency else { return }

        bands[index].frequency = frequency
    }

    private func logDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(log(max(lhs, 1) / max(rhs, 1)))
    }
}

/// Telemetry invalidates only a band's artwork, never its native fields or menus.
struct SpectrumBandLevelObserver<Content: View>: View {
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let frequency: Double
    @ViewBuilder var content: (Double) -> Content
    @State private var level: Double = -100

    var body: some View {
        content(level)
            .onReceive(spectrum.$points.throttle(for: .milliseconds(80), scheduler: DispatchQueue.main, latest: true)) {
                update($0, activeProfileID: spectrum.activeProfileID)
            }
            .onReceive(spectrum.$activeSession) { update(spectrum.points, activeProfileID: $0?.profileID) }
            .onChange(of: frequency) { _ in update(spectrum.points, activeProfileID: spectrum.activeProfileID) }
    }

    private func update(_ points: [SpectrumPoint], activeProfileID: UUID?) {
        guard activeProfileID == profileID, !points.isEmpty else {
            if level != -100 { level = -100 }; return
        }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 } else { upper = middle }
        }
        let index: Int
        if lower == 0 { index = 0 }
        else if lower == points.count { index = lower - 1 }
        else {
            let before = abs(log(max(points[lower - 1].frequency, 1) / max(frequency, 1)))
            let after = abs(log(max(points[lower].frequency, 1) / max(frequency, 1)))
            index = before <= after ? lower - 1 : lower
        }
        if level != points[index].db { level = points[index].db }
    }
}

// MARK: - Per-channel optimized strip

/// Per-channel EQ deliberately uses reference-backed band rows. A continuous
/// gain drag publishes only the one PerChannelBandState being edited instead of
/// replacing the parent [EQBand] value and invalidating the entire editor.
struct PerChannelGraphicEqualizerBands: View {
    var metrics = EQControlMetrics()
    @ObservedObject var bands: PerChannelBandsState
    let responses: PerChannelResponseState
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat
    let onBandChanged: @MainActor () -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 5 * metrics.scale) {
            VStack(spacing: 7 * metrics.scale) {
                Text("dB")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24 * metrics.scale)
                GainScaleLabels()
                    .frame(width: 32 * metrics.scale, height: metrics.sliderHeight)
            }
            .frame(width: 32 * metrics.scale)

            ForEach(bands.items) { bandState in
                PerChannelBandColumnHost(
                    bandState: bandState,
                    responses: responses,
                    setKind: setKind,
                    commitFrequency: { frequency in
                        bands.commitFrequency(frequency, for: bandState.id)
                        onBandChanged()
                    },
                    onBandChanged: onBandChanged,
                    onGainEditingChanged: onGainEditingChanged
                )
                .frame(width: columnWidth)
            }
        }
        .padding(.vertical, 8 * metrics.scale)
        .background(alignment: .topLeading) {
            EQGainGuideGrid()
        }
    }
}

private struct PerChannelBandColumnHost: View {
    @ObservedObject var bandState: PerChannelBandState
    @ObservedObject var responses: PerChannelResponseState
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let commitFrequency: @MainActor (Double) -> Void
    let onBandChanged: @MainActor () -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        EQBandColumn(
            band: Binding(
                get: { bandState.band },
                set: { updated in
                    guard updated != bandState.band else { return }
                    bandState.band = updated
                    onBandChanged()
                }
            ),
            audioDB: -100,
            responseDB: responseGain(at: bandState.band.frequency),
            setKind: setKind,
            commitFrequency: commitFrequency,
            onGainEditingChanged: onGainEditingChanged
        )
    }

    private func responseGain(at frequency: Double) -> Double {
        let points = responses.filterResponse
        guard !points.isEmpty else { return 0 }

        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return points[0].gainDB }
        if lower == points.count { return points[lower - 1].gainDB }
        let before = points[lower - 1]
        let after = points[lower]
        return logDistance(before.frequency, frequency) <= logDistance(after.frequency, frequency)
            ? before.gainDB
            : after.gainDB
    }

    private func logDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(log(max(lhs, 1) / max(rhs, 1)))
    }
}

/// All EQ strips share point-based, text-scaled geometry. The scroll width is
/// derived from the same metrics as the controls, including the gain ruler.
struct EQControlMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) var scale: CGFloat = 1
    var columnWidth: CGFloat { 96 * scale }
    var sliderHeight: CGFloat { 220 * scale }
    var stripHeight: CGFloat { 402 * scale }
}

struct EqualizerBandScrollView<Content: View>: View {
    let bandCount: Int
    @ViewBuilder let content: (CGFloat) -> Content
    var metrics = EQControlMetrics()

    var body: some View {
        OverflowAwareHorizontalScrollView(
            contentWidth: GraphicEqualizerBands.requiredContentWidth(
                bandCount: bandCount, columnWidth: metrics.columnWidth, scale: metrics.scale),
            height: metrics.stripHeight
        ) {
            content(metrics.columnWidth)
        }
    }
}
