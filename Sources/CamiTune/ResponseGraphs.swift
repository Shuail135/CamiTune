import Combine
import SwiftUI

struct LineGraph: View {
    let points: [(Double, Double)]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var zeroLine: Bool = false
    var lineColor: Color = .primary
    var fillsArea: Bool = false

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
            HStack {
                Text("20"); Spacer(); Text("100"); Spacer(); Text("1k"); Spacer(); Text("10k"); Spacer(); Text("20k Hz")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .offset(y: 16)
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
            .padding(.bottom, 16)
            .padding(.leading, 4)
        }
        .padding(.bottom, 16)
    }

    private func x(_ value: Double, width: Double) -> Double {
        let clamped = min(max(value, xRange.lowerBound), xRange.upperBound)
        let a = log10(xRange.lowerBound)
        let b = log10(xRange.upperBound)
        return (log10(clamped) - a) / (b - a) * width
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
        let freqs = [20.0, 100, 1000, 10000, 20000]
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

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawGrid(context: &context, size: size)
            drawLine(
                points: spectrum,
                yRange: spectrumRange,
                color: .green,
                width: 1.7,
                fillsArea: true,
                context: &context,
                size: size
            )
            drawLine(
                points: response,
                yRange: responseRange,
                color: .blue,
                width: 1.4,
                fillsArea: false,
                context: &context,
                size: size
            )
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text("20"); Spacer(); Text("100"); Spacer(); Text("1k"); Spacer(); Text("10k"); Spacer(); Text("20k Hz")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .offset(y: 16)
        }
        .overlay(alignment: .leading) {
            axisLabels(range: spectrumRange)
                .padding(.leading, 4)
        }
        .overlay(alignment: .trailing) {
            axisLabels(range: responseRange, signed: true)
                .foregroundStyle(.blue)
                .padding(.trailing, 4)
        }
        .padding(.bottom, 16)
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
        .padding(.bottom, 16)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for frequency in [20.0, 100, 1000, 10000, 20000] {
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
            context.stroke(zero, with: .color(Color.blue.opacity(0.3)), lineWidth: 1)
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
        let clamped = min(max(value, xRange.lowerBound), xRange.upperBound)
        let minimum = log10(xRange.lowerBound)
        let span = log10(xRange.upperBound) - minimum
        return (log10(clamped) - minimum) / span * width
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
