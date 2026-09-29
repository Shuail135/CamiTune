import CamiTuneDomain
import SwiftUI

struct CorrectionResponseGraph: View {
    @State private var localVisibleCurves: Set<CorrectionGraphCurve>
    private let visibleCurves: Binding<Set<CorrectionGraphCurve>>?
    @State private var localShowControlPoints = true
    private let showControlPoints: Binding<Bool>?

    private var visibility: Binding<Set<CorrectionGraphCurve>> { visibleCurves ?? $localVisibleCurves }
    private var controlPointVisibility: Binding<Bool> { showControlPoints ?? $localShowControlPoints }
    @StateObject private var responseCache = CorrectionGraphResponseCache()
    @State private var editingBand: EQBand?
    @State private var dragOrigin: EQBand?
    let profile: DeviceCorrectionProfile
    let sampleRate: Double
    var onEdit: ((EQBand) -> Void)? = nil
    @Binding var selectedBandID: UUID?
    private var presentation: CorrectionGraphPresentation { .init(profile: profile) }

    init(profile: DeviceCorrectionProfile, sampleRate: Double, onEdit: ((EQBand) -> Void)? = nil, selectedBandID: Binding<UUID?> = .constant(nil), visibleCurves: Binding<Set<CorrectionGraphCurve>>? = nil, showControlPoints: Binding<Bool>? = nil) {
        self._localVisibleCurves = State(initialValue: profile.importedAPOText ? [.equalizer] : AutoEQPresentationPreferences().visibleCurves)
        self.visibleCurves = visibleCurves
        self.showControlPoints = showControlPoints
        self.profile = profile
        self.sampleRate = sampleRate
        self.onEdit = onEdit
        self._selectedBandID = selectedBandID
    }

    var body: some View {
        // Read gesture state in this view, rather than only inside GeometryReader.
        // Every pointer event must invalidate the plotted response immediately.
        let filters = displayedFilters
        let selection = editingBand?.id ?? selectedBandID
        return VStack(spacing: 6) {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 48,
                y: 8,
                width: max(1, geometry.size.width - 60),
                height: max(1, geometry.size.height - 46)
            )
            let displayFrequencies = responseCache.displayFrequencies(count: min(
                1_536,
                max(512, Int(ceil(plot.width * 1.5)))
            ))
            let series = responseCache.series(profile: profile, filters: filters, sampleRate: sampleRate, frequencies: displayFrequencies)
            let measurement = series.measurement
            let target = series.target
            let corrected = series.corrected
            let equalizer = series.equalizer
            let error = series.error
            let levelRange: ClosedRange<Double> = onEdit == nil ? levelRange(for: [measurement, target, corrected, equalizer, error]) : -24...24
            let levelTicks = ticks(for: levelRange)
            let frequencyLabels = CorrectionGraphFrequencyAxis.labels(plotWidth: plot.width)
            ZStack {
                Canvas { context, _ in
                    let minorGrid = Path { path in
                        for frequency in CorrectionGraphFrequencyAxis.gridFrequencies {
                            let lineX = x(Double(frequency), plot: plot)
                            path.move(to: CGPoint(x: lineX, y: plot.minY))
                            path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                        }
                    }
                    context.stroke(minorGrid, with: .color(.secondary.opacity(0.09)), lineWidth: 0.5)
                    let grid = Path { path in
                        for gain in levelTicks {
                            let lineY = y(gain, plot: plot, range: levelRange)
                            path.move(to: CGPoint(x: plot.minX, y: lineY))
                            path.addLine(to: CGPoint(x: plot.maxX, y: lineY))
                        }
                        for frequency in frequencyLabels {
                            let lineX = x(Double(frequency), plot: plot)
                            path.move(to: CGPoint(x: lineX, y: plot.minY))
                            path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                        }
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    context.clip(to: Path(plot))
                    let curves: [(CorrectionGraphCurve, [(Double, Double)], Color, StrokeStyle)] = [
                        (.target, target, .blue.opacity(0.35), responseStroke(lineWidth: 7.5)),
                        (.measurement, measurement, .secondary, responseStroke(lineWidth: 1.2)),
                        (.corrected, corrected, .green, responseStroke(lineWidth: 2)),
                        (.equalizer, equalizer, .orange, responseStroke(lineWidth: 1.4)),
                        (.residual, error, .red, responseStroke(lineWidth: 1.3, dash: [3, 3])),
                        (.desired, presentation.speakerMode == .nearField ? series.desired : profile.curve.points.map { ($0.frequency, $0.gainDB) }, .purple, responseStroke(lineWidth: 1.3, dash: [4, 3]))
                    ]
                    for (curve, points, color, stroke) in curves where presentation.curves.contains(curve) && visibility.wrappedValue.contains(curve) {
                        context.stroke(responsePath(points, plot: plot, range: levelRange), with: .color(color), style: stroke)
                    }
                }
                .allowsHitTesting(false)
                ForEach(levelTicks, id: \.self) { gain in
                    Text(levelLabel(gain))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(
                            x: plot.minX - 15,
                            y: y(gain, plot: plot, range: levelRange)
                        )
                }
                ForEach(frequencyLabels, id: \.self) { frequency in
                    Text(CorrectionGraphFrequencyAxis.label(frequency))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: x(Double(frequency), plot: plot), y: plot.maxY + 10)
                }
                if onEdit != nil && controlPointVisibility.wrappedValue {
                    ForEach(filters) { band in
                        if let level = series.handleLevel(at: band.frequency, visibleCurves: visibility.wrappedValue) {
                            let center = CGPoint(x: x(band.frequency, plot: plot), y: y(level, plot: plot, range: levelRange))
                            Circle().fill(band.enabled ? Color.accentColor : Color.secondary)
                                .frame(width: selection == band.id ? 13 : 10, height: selection == band.id ? 13 : 10)
                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                .position(center)
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("correctionPlot"))
                                    .onChanged { value in
                                        updateDrag(band, translation: value.translation, plot: plot, range: levelRange)
                                    }
                                    .onEnded { value in
                                        updateDrag(band, translation: value.translation, plot: plot, range: levelRange)
                                        finishDrag()
                                    })
                                .accessibilityLabel("Band at \(Int(band.frequency)) Hz")
                            if selection == band.id {
                                let width = 2 * asinh(1 / (2 * (band.q ?? 0.707))) / log(2)
                                ForEach([-1.0, 1.0], id: \.self) { side in
                                    let frequency = min(20_000, max(20, band.frequency * pow(2, side * width / 2)))
                                    Rectangle().fill(Color.accentColor).frame(width: 5, height: 20)
                                        .position(x: x(frequency, plot: plot), y: center.y)
                                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("correctionPlot"))
                                            .onChanged { value in
                                                updateDrag(band, translation: value.translation, plot: plot, range: levelRange, bandwidthSide: side)
                                            }
                                            .onEnded { value in
                                                updateDrag(band, translation: value.translation, plot: plot, range: levelRange, bandwidthSide: side)
                                                finishDrag()
                                            })
                                        .help("Bandwidth")
                                }
                            }
                        }
                    }
                }
                Text("Relative level (dB)")
                    .font(.system(size: 9).weight(.medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(-90))
                    .position(x: 8, y: plot.midY)
                Text("Frequency (Hz)")
                    .font(.system(size: 9).weight(.medium))
                    .foregroundStyle(.secondary)
                    .position(x: plot.midX, y: geometry.size.height - 5)
            }
            .transaction { $0.animation = nil }
            .coordinateSpace(name: "correctionPlot")
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        HStack(spacing: 14) {
            ForEach(presentation.curves, id: \.self) { curve in
                overlayToggle(curve, color: presentation.color(for: curve))
            }
            if onEdit != nil {
                Button {
                    controlPointVisibility.wrappedValue.toggle()
                } label: {
                    Label("Control Points", systemImage: "circle.fill")
                        .foregroundStyle(controlPointVisibility.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .accessibilityValue(controlPointVisibility.wrappedValue ? "Shown" : "Hidden")
            }
        }.font(.caption)
        }
    }

    private var displayedFilters: [EQBand] {
        guard let editingBand else { return profile.filters }
        return profile.filters.map { $0.id == editingBand.id ? editingBand : $0 }
    }

    private func updateDrag(_ band: EQBand, translation: CGSize, plot: CGRect, range: ClosedRange<Double>, bandwidthSide: Double? = nil) {
        let origin = dragOrigin ?? band
        if dragOrigin == nil { dragOrigin = origin }
        editingBand = CorrectionGraphDrag.band(from: origin, translation: translation, plot: plot,
            range: range, sampleRate: sampleRate, bandwidthSide: bandwidthSide,
            speakerSettings: profile.speakerProvenance?.settings)
    }

    private func finishDrag() {
        if let editingBand {
            if selectedBandID != editingBand.id { selectedBandID = editingBand.id }
            if profile.filters.first(where: { $0.id == editingBand.id }) != editingBand { onEdit?(editingBand) }
        }
        editingBand = nil
        dragOrigin = nil
    }

    private func overlayToggle(_ curve: CorrectionGraphCurve, color: Color) -> some View {
        Button {
            if visibility.wrappedValue.contains(curve) {
                visibility.wrappedValue.remove(curve)
            } else {
                visibility.wrappedValue.insert(curve)
            }
        } label: {
            Label(presentation.label(for: curve), systemImage: "minus").foregroundStyle(visibility.wrappedValue.contains(curve) ? color : Color.secondary.opacity(0.4))
        }.buttonStyle(.plain).accessibilityValue(visibility.wrappedValue.contains(curve) ? "Shown" : "Hidden")
    }

    private func responsePath(
        _ points: [(Double, Double)],
        plot: CGRect,
        range: ClosedRange<Double>
    ) -> Path {
        let positions = points.map {
            CGPoint(
                x: x($0.0, plot: plot),
                y: y($0.1, plot: plot, range: range)
            )
        }
        return Path { path in
            guard let first = positions.first else { return }
            path.move(to: first)
            guard positions.count > 1 else { return }
            if positions.count == 2 {
                path.addLine(to: positions[1])
                return
            }
            for index in 0..<(positions.count - 1) {
                let previous = positions[max(0, index - 1)]
                let start = positions[index]
                let end = positions[index + 1]
                let following = positions[min(positions.count - 1, index + 2)]
                let minimumY = min(start.y, end.y)
                let maximumY = max(start.y, end.y)
                let control1 = CGPoint(
                    x: min(end.x, max(start.x, start.x + (end.x - previous.x) / 6)),
                    y: min(maximumY, max(minimumY, start.y + (end.y - previous.y) / 6))
                )
                let control2 = CGPoint(
                    x: min(end.x, max(start.x, end.x - (following.x - start.x) / 6)),
                    y: min(maximumY, max(minimumY, end.y - (following.y - start.y) / 6))
                )
                path.addCurve(to: end, control1: control1, control2: control2)
            }
        }
    }

    private func responseStroke(
        lineWidth: CGFloat,
        dash: [CGFloat] = []
    ) -> StrokeStyle {
        StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: dash
        )
    }

    private func x(_ frequency: Double, plot: CGRect) -> Double {
        plot.minX + min(plot.width, max(0, log(frequency / 20) / log(1_000) * plot.width))
    }

    private func levelRange(
        for series: [[(Double, Double)]]
    ) -> ClosedRange<Double> {
        let maximumMagnitude = series.lazy.flatMap { $0 }.map {
            abs($0.1)
        }.filter(\.isFinite).max() ?? 18
        let extent = max(18, ceil(maximumMagnitude * 1.08 / 6) * 6)
        return -extent...extent
    }

    private func ticks(for range: ClosedRange<Double>) -> [Double] {
        let extent = range.upperBound
        return [-extent, -extent / 2, 0, extent / 2, extent]
    }

    private func y(
        _ gain: Double,
        plot: CGRect,
        range: ClosedRange<Double>
    ) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, gain))
        let position = (range.upperBound - clamped)
            / (range.upperBound - range.lowerBound)
        return plot.minY + position * plot.height
    }

    private func levelLabel(_ gain: Double) -> String {
        let rounded = Int(gain.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

}

/// Speaker graphs share drawing/interaction, with only physically meaningful
/// curves offered for the selected model-based listening mode.
struct CorrectionGraphPresentation {
    let speakerMode: SpeakerListeningMode?
    init(profile: DeviceCorrectionProfile) { speakerMode = profile.speakerProvenance?.listeningMode }
    var curves: [CorrectionGraphCurve] {
        switch speakerMode {
        case .nearField: return [.measurement, .target, .corrected, .equalizer, .desired, .residual]
        case .farField: return [.measurement, .corrected, .equalizer]
        case nil: return [.measurement, .target, .corrected, .equalizer, .desired, .residual]
        }
    }
    func label(for curve: CorrectionGraphCurve) -> String {
        if speakerMode != nil {
            if curve == .measurement { return "Original" }
            if curve == .target { return "Flat Reference" }
        }
        return curve.rawValue
    }
    func color(for curve: CorrectionGraphCurve) -> Color {
        switch curve {
        case .measurement: return .secondary
        case .target: return .blue
        case .corrected: return .green
        case .equalizer: return .orange
        case .desired: return .purple
        case .residual: return .red
        }
    }
}

enum CorrectionGraphFrequencyAxis {
    static let gridFrequencies: [Int] = [20, 30, 40, 50, 60, 70, 80, 90,
        100, 200, 300, 400, 500, 600, 700, 800, 900,
        1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000, 10_000, 20_000]

    static func label(_ frequency: Int) -> String {
        frequency >= 1_000 ? "\(frequency / 1_000)k" : "\(frequency)"
    }

    static func labels(plotWidth: CGFloat) -> [Int] {
        // Preserve the endpoints and decades, then fill available space without collisions.
        let priority = [20, 20_000, 100, 1_000, 10_000, 50, 200, 500, 2_000, 5_000]
        var selected: [Int] = []
        for frequency in priority + gridFrequencies where !selected.contains(frequency) {
            let fits = selected.allSatisfy { other in
                let distance = abs(log(Double(frequency) / Double(other))) / log(1_000) * plotWidth
                let minimumDistance = Double(label(frequency).count + label(other).count) * 3 + 8
                return distance >= minimumDistance
            }
            if fits { selected.append(frequency) }
        }
        return selected.sorted()
    }
}

/// Pure display memoization: resizing or a source change invalidates the grid;
/// moving a handle recalculates only that band's response.
final class CorrectionGraphResponseCache: ObservableObject {
    struct Series {
        var measurement: [(Double, Double)] = []
        var target: [(Double, Double)] = []
        var corrected: [(Double, Double)] = []
        var equalizer: [(Double, Double)] = []
        var error: [(Double, Double)] = []
        var desired: [(Double, Double)] = []

        func handleLevel(at frequency: Double, visibleCurves: Set<CorrectionGraphCurve>) -> Double? {
            if !corrected.isEmpty {
                return level(at: frequency, in: corrected)
            }
            // Imported filter-only profiles have no measured/corrected response.
            // Their controls use EQ; toggling lines never changes the anchor.
            return level(at: frequency, in: equalizer)
        }

        private func level(at frequency: Double, in points: [(Double, Double)]) -> Double? {
            guard let first = points.first, let last = points.last,
                  frequency >= first.0, frequency <= last.0 else { return nil }
            var lower = 0
            var upper = points.count - 1
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if points[middle].0 <= frequency { lower = middle } else { upper = middle }
            }
            guard lower != upper else { return first.1 }
            let start = points[lower], end = points[upper]
            let fraction = log(frequency / start.0) / log(end.0 / start.0)
            return start.1 + fraction * (end.1 - start.1)
        }
    }
    private var displayGrid: [Double] = []
    private var totalGains: [Double] = []
    private var lastSeries: Series?
    private var grid: [Double] = []
    private var rate: Double = 0
    private var measurement: FrequencyResponse?
    private var target: FrequencyResponse?
    private var measuredValues: [Double?] = []
    private var targetValues: [Double?] = []
    private var bands: [UUID: (EQBand, [Double])] = [:]
    private(set) var bandEvaluationCount = 0
    private(set) var seriesBuildCount = 0

    func displayFrequencies(count: Int) -> [Double] {
        if displayGrid.count != count {
            displayGrid = (0..<count).map { 20 * pow(1_000, Double($0) / Double(max(1, count - 1))) }
        }
        return displayGrid
    }

    func series(profile: DeviceCorrectionProfile, filters: [EQBand], sampleRate: Double, frequencies: [Double]) -> Series {
        if grid != frequencies || rate != sampleRate {
            grid = frequencies
            rate = sampleRate
            measurement = nil
            target = nil
            bands.removeAll()
            totalGains = Array(repeating: 0, count: grid.count)
            lastSeries = nil
        }
        if measurement != profile.measurement {
            lastSeries = nil
            measurement = profile.measurement
            let normalized = profile.measurement.normalized()
            measuredValues = grid.map { normalized.displayMagnitude(at: $0) }
        }
        if target != profile.target {
            lastSeries = nil
            target = profile.target
            let normalized = profile.target.normalized()
            targetValues = grid.map { normalized.displayMagnitude(at: $0) }
        }
        let ids = Set(filters.map(\.id))
        for id in Array(bands.keys) where !ids.contains(id) {
            if let removed = bands.removeValue(forKey: id) {
                for index in grid.indices { totalGains[index] -= removed.1[index] }
                lastSeries = nil
            }
        }
        for band in filters where bands[band.id]?.0 != band {
            let values = EQResponseCalculator().gainsDB(at: grid,
                parsed: ParsedEQ(preampDB: 0, bands: [band], warnings: []), sampleRate: rate)
            let previous = bands[band.id]?.1
            for index in grid.indices { totalGains[index] += values[index] - (previous?[index] ?? 0) }
            bands[band.id] = (band, values)
            bandEvaluationCount += 1
            lastSeries = nil
        }
        if let lastSeries { return lastSeries }
        seriesBuildCount += 1
        var result = Series()
        for index in grid.indices {
            let frequency = grid[index], gain = totalGains[index]
            result.equalizer.append((frequency, gain))
            if let measured = measuredValues[index] {
                result.measurement.append((frequency, measured))
                result.corrected.append((frequency, measured + gain))
                if let target = targetValues[index] {
                    result.error.append((frequency, measured + gain - target))
                    result.desired.append((frequency, target - measured))
                }
            }
            if let target = targetValues[index] { result.target.append((frequency, target)) }
        }
        lastSeries = result
        return result
    }
}

/// Use displacement from the original grab position: a mouse-down does not
/// change the filter, and even a one-pixel movement updates the response.
enum CorrectionGraphDrag {
    static func band(from origin: EQBand, translation: CGSize, plot: CGRect,
                     range: ClosedRange<Double>, sampleRate: Double, bandwidthSide: Double? = nil,
                     speakerSettings: SpeakerCorrectionSettings? = nil) -> EQBand {
        guard translation != .zero else { return origin }
        var edited = origin
        if let side = bandwidthSide {
            let q = origin.q ?? 0.707
            let width = 2 * asinh(1 / (2 * q)) / log(2)
            let edge = min(20_000, max(20, origin.frequency * pow(2, side * width / 2)))
            let position = min(1, max(0, log(edge / 20) / log(1_000) + translation.width / plot.width))
            let movedEdge = 20 * pow(1_000, position)
            let octaves = max(0.02, 2 * abs(log2(movedEdge / origin.frequency)))
            edited.q = min(12, max(0.1, 1 / (2 * sinh(log(2) * octaves / 2))))
            edited.bandwidth = nil
        } else {
            let position = min(1, max(0, log(origin.frequency / 20) / log(1_000) + translation.width / plot.width))
            edited.frequency = min(sampleRate * 0.49, 20 * pow(1_000, position))
            let gain = (origin.gain ?? 0) - translation.height / plot.height * (range.upperBound - range.lowerBound)
            edited.gain = min(12, max(-24, gain))
        }
        if let bounds = speakerSettings {
            edited.frequency = min(min(bounds.maxFrequency, sampleRate * 0.49), max(bounds.minFrequency, edited.frequency))
            edited.gain = min(bounds.maximumGainDB, max(bounds.minimumGainDB, edited.gain ?? 0))
            edited.q = min(bounds.maximumQ, max(bounds.minimumQ, edited.q ?? 1))
        }
        return edited
    }
}
