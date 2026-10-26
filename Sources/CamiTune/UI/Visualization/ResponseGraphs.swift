import Combine
import SwiftUI

struct LineGraph: View {
    let points: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var zeroLine: Bool = false
    var lineColor: Color = .primary
    var fillsArea: Bool = false
    var usesSpectrumLayout = false
    @ScaledMetric(relativeTo: .caption2) private var axisScale: CGFloat = 1

    var body: some View {
        if usesSpectrumLayout {
            SpectrumGraphLayout(range: yRange, scale: axisScale) { plot }
        } else {
            HStack(spacing: 6 * axisScale) {
                GraphDecibelAxis(range: yRange, scale: axisScale)
                    .offset(x: 16 * axisScale)
                plot
                    .padding(.vertical, 16 * axisScale)
            }
        }
    }

    private var plot: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let plot = ResponseGraphPlot(xRange: xRange, size: size, scale: axisScale)
            plot.drawGrid(context: &context, zeroRange: zeroLine ? yRange : nil)
            plot.drawLine(points, yRange: yRange, color: lineColor, width: 1.8,
                fillOpacity: fillsArea ? 0.34 : nil, context: &context)
        }
        .overlay(alignment: .bottom) {
            SpectrumFrequencyAxis(xRange: xRange, scale: axisScale)
                .frame(height: 16 * axisScale)
                .offset(y: 16 * axisScale)
        }
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
        SpectrumGraphLayout(range: spectrumRange, responseRange: responseRange, scale: axisScale) {
            plot
        }
    }

    private var plot: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let plot = ResponseGraphPlot(xRange: xRange, size: size, scale: axisScale)
            plot.drawGrid(context: &context, zeroRange: responseRange,
                zeroColor: CorrectionGraphPresentation.equalizerColor.opacity(0.3))
            plot.drawLine(spectrum, yRange: spectrumRange, color: .blue, width: 1.7,
                fillOpacity: 0.36, context: &context)
            plot.drawLine(response, yRange: responseRange,
                color: CorrectionGraphPresentation.equalizerColor, width: 1.4, context: &context)
        }
        .overlay(alignment: .bottom) {
            SpectrumFrequencyAxis(xRange: xRange, scale: axisScale)
                .frame(height: 16 * axisScale)
                .offset(y: 16 * axisScale)
        }
    }

}

struct ResponseGraphPlot {
    let xRange: ClosedRange<Double>
    let size: CGSize
    let scale: CGFloat

    func x(_ value: Double) -> Double {
        SpectrumFrequencyTicks.x(value, in: xRange, width: size.width, scale: scale)
    }

    func y(_ value: Double, range: ClosedRange<Double>) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return size.height - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound) * size.height
    }

    func path(_ points: [(Double, Double)], yRange: ClosedRange<Double>) -> Path {
        let mapped = points.map { CGPoint(x: x($0.0), y: y($0.1, range: yRange)) }
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

    func drawGrid(context: inout GraphicsContext, zeroRange: ClosedRange<Double>? = nil,
        zeroColor: Color = .primary.opacity(0.25)) {
        for frequency in SpectrumFrequencyTicks.values(in: xRange) {
            var path = Path()
            let xx = x(frequency)
            path.move(to: CGPoint(x: xx, y: 0))
            path.addLine(to: CGPoint(x: xx, y: size.height))
            context.stroke(path, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        if let zeroRange, zeroRange.contains(0) {
            var path = Path()
            let yy = y(0, range: zeroRange)
            path.move(to: CGPoint(x: x(xRange.lowerBound), y: yy))
            path.addLine(to: CGPoint(x: x(xRange.upperBound), y: yy))
            context.stroke(path, with: .color(zeroColor), lineWidth: 1)
        }
    }

    func drawLine(_ points: [(Double, Double)], yRange: ClosedRange<Double>, color: Color,
        width: Double, fillOpacity: Double? = nil, context: inout GraphicsContext) {
        guard points.count > 1, let first = points.first, let last = points.last else { return }
        let path = path(points, yRange: yRange)
        if let fillOpacity {
            var fill = path
            fill.addLine(to: CGPoint(x: x(last.0), y: size.height))
            fill.addLine(to: CGPoint(x: x(first.0), y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(fillOpacity), color.opacity(0.04)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}

/// Both spectrum panels use identical plot bounds. The response scale fits in
/// the existing right margin instead of narrowing the post-EQ graph.
private struct SpectrumGraphLayout<Plot: View>: View {
    let range: ClosedRange<Double>
    var responseRange: ClosedRange<Double>? = nil
    let scale: CGFloat
    @ViewBuilder var plot: () -> Plot

    var body: some View {
        HStack(spacing: 6 * scale) {
            GraphDecibelAxis(range: range, scale: scale)
            plot()
                // Use part of the plot's 24 pt inset for the label column.
                .padding(.leading, -16 * scale)
                .padding(.vertical, 16 * scale)
        }
        .overlay(alignment: .trailing) {
            if let responseRange {
                GraphDecibelAxis(range: responseRange, scale: scale, signed: true, alignment: .leading,
                    color: CorrectionGraphPresentation.equalizerColor)
            }
        }
    }
}

/// Give level labels their own column so even wide values stay outside the grid.
private struct GraphDecibelAxis: View {
    let range: ClosedRange<Double>
    let scale: CGFloat
    var signed = false
    var alignment: HorizontalAlignment = .trailing
    var color: Color = .secondary

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text("dB")
                .frame(height: 16 * scale, alignment: .top)
            VStack(alignment: alignment, spacing: 0) {
                Text(label(range.upperBound))
                Spacer(minLength: 0)
                Text(label((range.lowerBound + range.upperBound) / 2))
                Spacer(minLength: 0)
                Text(label(range.lowerBound))
            }
            .padding(.bottom, 16 * scale)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(color)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func label(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return signed && value > 0 ? "+\(number)" : number
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
            let characters = label(left).count + label(right).count
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
        // Axis labels are artwork, not controls. Draw them with the graph so
        // each animated width does not rebuild eight Text/GeometryReader trees.
        Canvas(rendersAsynchronously: true) { context, size in
            let frequencies = SpectrumFrequencyTicks.values(in: xRange)
            let fontSize = SpectrumFrequencyTicks.fontSize(in: xRange, width: size.width, scale: scale)
            for frequency in frequencies {
                let label = context.resolve(Text(SpectrumFrequencyTicks.label(frequency))
                    .font(.system(size: fontSize).monospacedDigit())
                    .foregroundColor(.secondary))
                let x = SpectrumFrequencyTicks.x(frequency, in: xRange, width: size.width, scale: scale)
                context.draw(label, at: CGPoint(x: x, y: 8 * scale))
                if frequency == frequencies.last {
                    let labelSize = label.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
                    let unit = context.resolve(Text("Hz")
                        .font(.system(size: fontSize).monospacedDigit())
                        .foregroundColor(.secondary))
                    context.draw(unit, at: CGPoint(x: x + labelSize.width / 2 + 3 * scale, y: 8 * scale), anchor: .leading)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Frequency in hertz")
        .accessibilityValue(SpectrumFrequencyTicks.values(in: xRange).map { String(Int($0)) }.joined(separator: ", "))
    }
}
