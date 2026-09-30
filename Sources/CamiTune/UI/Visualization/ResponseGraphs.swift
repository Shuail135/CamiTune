import Combine
import SwiftUI

struct LineGraph: View {
    let points: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var zeroLine: Bool = false
    var lineColor: Color = .primary
    var fillsArea: Bool = false
    @ScaledMetric(relativeTo: .caption2) private var axisScale: CGFloat = 1

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            drawGrid(context: &context, rect: rect)
            guard points.count > 1,
                  let firstPoint = points.first,
                  let lastPoint = points.last else { return }
            let path = smoothPath(points: points, size: size)
            if fillsArea {
                var fill = path
                fill.addLine(to: CGPoint(x: x(lastPoint.0, width: size.width), y: size.height))
                fill.addLine(to: CGPoint(x: x(firstPoint.0, width: size.width), y: size.height))
                fill.closeSubpath()
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [lineColor.opacity(0.34), lineColor.opacity(0.04)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            context.stroke(path, with: .color(lineColor), lineWidth: 1.8)
        }
        .overlay(alignment: .bottom) {
            SpectrumFrequencyAxis(xRange: xRange, scale: axisScale)
                .frame(height: 16 * axisScale)
                .offset(y: 16 * axisScale)
        }
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(dbLabel(yRange.upperBound))
                Spacer()
                Text(dbLabel((yRange.lowerBound + yRange.upperBound) / 2))
                Spacer()
                Text(dbLabel(yRange.lowerBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
        .padding(.bottom, 16 * axisScale)
    }

    private func x(_ value: Double, width: Double) -> Double {
        SpectrumFrequencyTicks.x(value, in: xRange, width: width, scale: axisScale)
    }

    private func y(_ value: Double, height: Double) -> Double {
        let clamped = min(max(value, yRange.lowerBound), yRange.upperBound)
        return height - (clamped - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound) * height
    }

    private func smoothPath(points: [(Double, Double)], size: CGSize) -> Path {
        let mapped = points.map { CGPoint(x: x($0.0, width: size.width), y: y($0.1, height: size.height)) }
        var path = Path()
        guard let first = mapped.first else { return path }
        path.move(to: first)
        for index in 1..<mapped.count {
            let previous = mapped[index - 1]
            let current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) * 0.5, y: (previous.y + current.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        return path
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect) {
        let freqs = SpectrumFrequencyTicks.values(in: xRange)
        for f in freqs {
            var p = Path()
            let xx = x(f, width: rect.width)
            p.move(to: CGPoint(x: xx, y: 0)); p.addLine(to: CGPoint(x: xx, y: rect.height))
            context.stroke(p, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        if zeroLine, yRange.contains(0) {
            var p = Path()
            let yy = y(0, height: rect.height)
            p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: rect.width, y: yy))
            context.stroke(p, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
        }
    }

    private func dbLabel(_ value: Double) -> String {
        "\(Int(value.rounded())) dB"
    }
}

struct OverlayLineGraph: View {
    let input: [(Double, Double)]
    let output: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>

    var body: some View {
        ZStack {
            LineGraph(points: input, xRange: xRange, yRange: yRange, lineColor: .secondary)
            LineGraph(points: output, xRange: xRange, yRange: yRange, lineColor: .blue)
        }
    }
}

struct SpectrumWithResponseGraph: View {
    let spectrum: [(Double, Double)]
    let response: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let spectrumRange: ClosedRange<Double>
    let responseRange: ClosedRange<Double>
    @ScaledMetric(relativeTo: .caption2) private var axisScale: CGFloat = 1

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawGrid(context: &context, size: size)
            drawLine(
                points: spectrum,
                yRange: spectrumRange,
                color: .blue,
                width: 1.7,
                fillsArea: true,
                context: &context,
                size: size
            )
            drawLine(
                points: response,
                yRange: responseRange,
                color: CorrectionGraphPresentation.equalizerColor,
                width: 1.4,
                fillsArea: false,
                context: &context,
                size: size
            )
        }
        .overlay(alignment: .bottom) {
            SpectrumFrequencyAxis(xRange: xRange, scale: axisScale)
                .frame(height: 16 * axisScale)
                .offset(y: 16 * axisScale)
        }
        .overlay(alignment: .leading) {
            axisLabels(range: spectrumRange)
                .padding(.leading, 4)
        }
        .overlay(alignment: .trailing) {
            axisLabels(range: responseRange, signed: true)
                .foregroundStyle(CorrectionGraphPresentation.equalizerColor)
                .padding(.trailing, 4)
        }
        .padding(.bottom, 16 * axisScale)
    }

    private func axisLabels(range: ClosedRange<Double>, signed: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(dbLabel(range.upperBound, signed: signed))
            Spacer()
            Text(dbLabel((range.lowerBound + range.upperBound) / 2, signed: signed))
            Spacer()
            Text(dbLabel(range.lowerBound, signed: signed))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for frequency in SpectrumFrequencyTicks.values(in: xRange) {
            var path = Path()
            let xx = x(frequency, width: size.width)
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: size.height))
            context.stroke(path, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        if responseRange.contains(0) {
            var zero = Path()
            let yy = y(0, range: responseRange, height: size.height)
            zero.move(to: CGPoint(x: 0, y: yy))
            zero.addLine(to: CGPoint(x: size.width, y: yy))
            context.stroke(zero, with: .color(CorrectionGraphPresentation.equalizerColor.opacity(0.3)), lineWidth: 1)
        }
    }

    private func drawLine(
        points: [(Double, Double)],
        yRange: ClosedRange<Double>,
        color: Color,
        width: Double,
        fillsArea: Bool,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard points.count > 1,
              let firstPoint = points.first,
              let lastPoint = points.last else { return }
        let mapped = points.map {
            CGPoint(x: x($0.0, width: size.width), y: y($0.1, range: yRange, height: size.height))
        }
        var path = Path()
        if let first = mapped.first { path.move(to: first) }
        for index in 1..<mapped.count {
            let previous = mapped[index - 1]
            let current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) * 0.5, y: (previous.y + current.y) * 0.5)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        if fillsArea {
            var fill = path
            fill.addLine(to: CGPoint(x: x(lastPoint.0, width: size.width), y: size.height))
            fill.addLine(to: CGPoint(x: x(firstPoint.0, width: size.width), y: size.height))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.36), color.opacity(0.04)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func x(_ value: Double, width: Double) -> Double {
        SpectrumFrequencyTicks.x(value, in: xRange, width: width, scale: axisScale)
    }

    private func y(_ value: Double, range: ClosedRange<Double>, height: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return height - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound) * height
    }

    private func dbLabel(_ value: Double, signed: Bool) -> String {
        let rounded = Int(value.rounded())
        return signed && rounded > 0 ? "+\(rounded) dB" : "\(rounded) dB"
    }
}

/// Spectrum panels keep their original compact axis. The grid and labels use
/// exactly the same sparse ticks; Auto EQ owns its separate, denser axis.
private enum SpectrumFrequencyTicks {
    static func values(in range: ClosedRange<Double>) -> [Double] {
        let values: [Double] = [20, 80, 300, 1_000, 4_000, 6_000, 10_000, 20_000]
        return values.filter { range.contains($0) }
    }

    // Reserve equal margins for the endpoint labels. Curves, grid lines, and
    // labels all use this exact transform; labels never shift away from ticks.
    static func x(_ frequency: Double, in range: ClosedRange<Double>, width: CGFloat, scale: CGFloat) -> CGFloat {
        let inset = min(24 * scale, width / 2)
        let clamped = min(range.upperBound, max(range.lowerBound, frequency))
        let fraction = log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
        return inset + fraction * max(0, width - 2 * inset)
    }

    static func fontSize(in range: ClosedRange<Double>, width: CGFloat, scale: CGFloat) -> CGFloat {
        let frequencies = values(in: range)
        var result = 10 * scale
        for (left, right) in zip(frequencies, frequencies.dropFirst()) {
            let distance = x(right, in: range, width: width, scale: scale) - x(left, in: range, width: width, scale: scale)
            let characters = label(left).count + label(right).count + (right == frequencies.last ? 3 : 0)
            // Conservative character widths leave a gap between adjacent labels
            // while keeping all eight labels on the same baseline at any width.
            result = min(result, max(1, distance - 3 * scale) / (CGFloat(characters) * 0.65 / 2))
        }
        return result
    }

    static func label(_ frequency: Double) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }
}

private struct SpectrumFrequencyAxis: View {
    let xRange: ClosedRange<Double>
    let scale: CGFloat
    var body: some View {
        GeometryReader { geometry in
            let frequencies = SpectrumFrequencyTicks.values(in: xRange)
            let fontSize = SpectrumFrequencyTicks.fontSize(in: xRange, width: geometry.size.width, scale: scale)
            ForEach(frequencies, id: \.self) { frequency in
                let label = SpectrumFrequencyTicks.label(frequency) + (frequency == frequencies.last ? " Hz" : "")
                Text(label)
                    .font(.system(size: fontSize).monospacedDigit())
                    .fixedSize()
                    .position(x: SpectrumFrequencyTicks.x(frequency, in: xRange, width: geometry.size.width, scale: scale), y: 8 * scale)
            }
        }
        .foregroundStyle(.secondary)
    }
}
