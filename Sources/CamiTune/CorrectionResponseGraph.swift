import SwiftUI

struct CorrectionResponseGraph: View, Equatable {
    let profile: DeviceCorrectionProfile
    let sampleRate: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.sampleRate == rhs.sampleRate
    }

    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(
                x: 48,
                y: 8,
                width: max(1, geometry.size.width - 60),
                height: max(1, geometry.size.height - 46)
            )
            let displayFrequencies = frequencies(count: min(
                1_536,
                max(512, Int(ceil(plot.width * 1.5)))
            ))
            let series = responseSeries(at: displayFrequencies)
            let measurement = series.measurement
            let target = series.target
            let corrected = series.corrected
            let equalizer = series.equalizer
            let error = series.error
            let levelRange = levelRange(for: [
                measurement, target, corrected, equalizer, error
            ])
            let levelTicks = ticks(for: levelRange)
            ZStack {
                Path { path in
                    for gain in levelTicks {
                        let lineY = y(gain, plot: plot, range: levelRange)
                        path.move(to: CGPoint(x: plot.minX, y: lineY))
                        path.addLine(to: CGPoint(x: plot.maxX, y: lineY))
                    }
                    for frequency in [20.0, 100, 1_000, 10_000, 20_000] {
                        let lineX = x(frequency, plot: plot)
                        path.move(to: CGPoint(x: lineX, y: plot.minY))
                        path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)

                responsePath(measurement, plot: plot, range: levelRange)
                    .stroke(
                        Color.secondary,
                        style: responseStroke(lineWidth: 1.2)
                    )
                responsePath(target, plot: plot, range: levelRange)
                    .stroke(
                        Color.blue,
                        style: responseStroke(lineWidth: 1.4, dash: [5, 3])
                    )
                responsePath(corrected, plot: plot, range: levelRange)
                    .stroke(
                        Color.green,
                        style: responseStroke(lineWidth: 2)
                    )
                responsePath(equalizer, plot: plot, range: levelRange)
                    .stroke(
                        Color.orange,
                        style: responseStroke(lineWidth: 1.4)
                    )
                responsePath(error, plot: plot, range: levelRange)
                    .stroke(
                        Color.red,
                        style: responseStroke(lineWidth: 1.3, dash: [3, 3])
                    )

                ForEach(levelTicks, id: \.self) { gain in
                    Text(levelLabel(gain))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(
                            x: plot.minX - 15,
                            y: y(gain, plot: plot, range: levelRange)
                        )
                }
                ForEach([20, 100, 1_000, 10_000, 20_000], id: \.self) { frequency in
                    Text(frequencyLabel(frequency))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: x(Double(frequency), plot: plot), y: plot.maxY + 10)
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
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func frequencies(count: Int) -> [Double] {
        // Display density only. Policy and optimizer grids remain at 181 points.
        (0..<count).map { 20 * pow(1_000, Double($0) / Double(count - 1)) }
    }

    private struct ResponseSeries {
        var measurement: [(Double, Double)] = []
        var target: [(Double, Double)] = []
        var corrected: [(Double, Double)] = []
        var equalizer: [(Double, Double)] = []
        var error: [(Double, Double)] = []
    }

    private func responseSeries(at frequencies: [Double]) -> ResponseSeries {
        let normalizedMeasurement = profile.measurement.normalized()
        let normalizedTarget = profile.target.normalized()
        let parsed = ParsedEQ(preampDB: 0, bands: profile.filters, warnings: [])
        let calculator = EQResponseCalculator()
        var result = ResponseSeries()
        result.measurement.reserveCapacity(frequencies.count)
        result.target.reserveCapacity(frequencies.count)
        result.corrected.reserveCapacity(frequencies.count)
        result.equalizer.reserveCapacity(frequencies.count)
        result.error.reserveCapacity(frequencies.count)

        for frequency in frequencies {
            let equalizerGain = calculator.gainDB(
                at: frequency,
                parsed: parsed,
                sampleRate: sampleRate
            )
            result.equalizer.append((frequency, equalizerGain))

            let measured = normalizedMeasurement.displayMagnitude(at: frequency)
            let target = normalizedTarget.displayMagnitude(at: frequency)
            if let measured {
                result.measurement.append((frequency, measured))
                result.corrected.append((frequency, measured + equalizerGain))
            }
            if let target {
                result.target.append((frequency, target))
            }
            if let measured, let target {
                result.error.append((frequency, measured + equalizerGain - target))
            }
        }
        return result
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

    private func frequencyLabel(_ frequency: Int) -> String {
        switch frequency {
        case 1_000: return "1k"
        case 10_000: return "10k"
        case 20_000: return "20k"
        default: return "\(frequency)"
        }
    }
}
