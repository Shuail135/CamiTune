import Combine
import SwiftUI

struct GraphicEqualizerBands: View {
    @Binding var bands: [EQBand]
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let responsePoints: [EQResponsePoint]
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat
    var showsSpectrumLevels = true
    var onGainEditingChanged: @MainActor (Bool) -> Void = { _ in }

    static func requiredContentWidth(
        bandCount: Int,
        columnWidth: CGFloat
    ) -> CGFloat {
        // The HStack contains a 32 pt gain scale followed by one 5 pt
        // inter-item gap and one fixed-width column per band.
        32 + CGFloat(max(0, bandCount)) * (columnWidth + 5)
    }

    @ViewBuilder
    var body: some View {
        if showsSpectrumLevels {
            SpectrumLevelObserver(
                spectrum: spectrum,
                profileID: profileID,
                bands: bands
            ) { audioLevels in
                bandColumns(audioLevels: audioLevels)
            }
        } else {
            // Channel-specific editors do not show live FFT levels, so avoid
            // subscribing to SpectrumAnalyzer at all in this branch.
            bandColumns(audioLevels: [:])
        }
    }

    private func bandColumns(audioLevels: [UUID: Double]) -> some View {
        HStack(alignment: .top, spacing: 5) {
            VStack(spacing: 7) {
                Text("dB")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                GainScaleLabels()
                    .frame(width: 32, height: 220)
            }
            .frame(width: 32)

            ForEach(bands) { band in
                EQBandColumn(
                    band: binding(for: band),
                    audioDB: audioLevels[band.id] ?? -100,
                    responseDB: responseGain(at: band.frequency),
                    setKind: setKind,
                    commitFrequency: { frequency in
                        commitFrequency(frequency, for: band.id)
                    },
                    onGainEditingChanged: onGainEditingChanged
                )
                .frame(width: columnWidth)
            }
        }
        .padding(.vertical, 8)
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

private struct SpectrumLevelObserver<Content: View>: View {
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let bands: [EQBand]
    let content: ([UUID: Double]) -> Content

    @State private var displayedLevels: [UUID: Double] = [:]

    var body: some View {
        content(displayedLevels)
            .onAppear {
                displayedLevels = audioLevels(
                    from: spectrum.points,
                    activeProfileID: spectrum.activeProfileID
                )
            }
            .onReceive(
                spectrum.$points.throttle(
                    for: .milliseconds(80),
                    scheduler: RunLoop.main,
                    latest: true
                )
            ) { points in
                let nextLevels = audioLevels(
                    from: points,
                    activeProfileID: spectrum.activeProfileID
                )
                guard nextLevels != displayedLevels else { return }
                // The analyzer can continue publishing at its normal rate, but
                // the EQ strip presents at most 12.5 updates/sec. One shared
                // animation transaction interpolates between those samples so
                // the meters still move continuously without rebuilding the
                // whole band strip for every FFT publication.
                withAnimation(.linear(duration: UIRenderPerformance.animatedLevelTransitionDuration)) {
                    displayedLevels = nextLevels
                }
            }
            .onReceive(spectrum.$activeSession) { session in
                // @Published emits before its stored property is updated, so use
                // the session value delivered by the publisher here.
                let nextLevels = audioLevels(
                    from: spectrum.points,
                    activeProfileID: session?.profileID
                )
                guard nextLevels != displayedLevels else { return }
                displayedLevels = nextLevels
            }
            .onChange(of: spectrumTargets) { _ in
                // A committed Hz change moves the lookup target immediately. The
                // next FFT publication resumes smooth movement from that position.
                displayedLevels = audioLevels(
                    from: spectrum.points,
                    activeProfileID: spectrum.activeProfileID
                )
            }
    }

    private var spectrumTargets: [BandSpectrumTarget] {
        bands.map { BandSpectrumTarget(id: $0.id, frequency: $0.frequency) }
    }

    private func audioLevels(
        from points: [SpectrumPoint],
        activeProfileID: UUID?
    ) -> [UUID: Double] {
        guard activeProfileID == profileID, !points.isEmpty else { return [:] }

        return Dictionary(uniqueKeysWithValues: bands.map { band in
            (band.id, nearestSpectrumDB(at: band.frequency, in: points))
        })
    }

    private func nearestSpectrumDB(
        at frequency: Double,
        in points: [SpectrumPoint]
    ) -> Double {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].frequency < frequency { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return points[0].db }
        if lower == points.count { return points[lower - 1].db }
        let before = points[lower - 1]
        let after = points[lower]
        return logDistance(before.frequency, frequency) <= logDistance(after.frequency, frequency)
            ? before.db
            : after.db
    }

    private func logDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(log(max(lhs, 1) / max(rhs, 1)))
    }

    private struct BandSpectrumTarget: Equatable {
        let id: UUID
        let frequency: Double
    }
}


// MARK: - Per-channel optimized strip

/// Per-channel EQ deliberately uses reference-backed band rows. A continuous
/// gain drag publishes only the one PerChannelBandState being edited instead of
/// replacing the parent [EQBand] value and invalidating the entire editor.
struct PerChannelGraphicEqualizerBands: View {
    @ObservedObject var bands: PerChannelBandsState
    let responses: PerChannelResponseState
    let setKind: (EQBand.Kind, inout EQBand) -> Void
    let columnWidth: CGFloat
    let onBandChanged: @MainActor () -> Void
    let onGainEditingChanged: @MainActor (Bool) -> Void

    var body: some View {
        LazyHStack(alignment: .top, spacing: 5) {
            VStack(spacing: 7) {
                Text("dB")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                GainScaleLabels()
                    .frame(width: 32, height: 220)
            }
            .frame(width: 32)

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
        .padding(.vertical, 8)
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
