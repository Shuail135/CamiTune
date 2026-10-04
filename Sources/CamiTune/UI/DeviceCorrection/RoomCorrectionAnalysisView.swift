import CamiTuneAudio
import CamiTuneDomain
import SwiftUI

private struct RoomPlotSeries: Sendable {
    var channel: Int
    var dashed = false
    var points: [SIMD2<Double>]
}
private func roomChannelColor(_ channel: Int) -> Color {
    let colors: [Color] = [.accentColor, .orange, .green, .purple, .pink, .cyan]
    return colors[max(0, channel) % colors.count]
}
@MainActor
struct RoomCorrectionAnalysisView: View {
    @ObservedObject var editor: RoomCorrectionEditorState
    @State private var view = "Frequency"
    @State private var hiddenChannels = Set<Int>()
    @State private var smoothed = true
    @State private var smoothing = 12
    @State private var reliability = false
    @State private var hidden = Set<UUID>()
    @State private var comparingSessions = false
    @State private var series: [RoomPlotSeries] = []
    @State private var timingAvailable = false
    @StateObject private var operation = UIBackgroundOperation<[RoomPlotSeries]>()
    private let modes = ["Frequency", "Positions", "Impulse", "Phase", "Group Delay"]
    private var supportsSmoothing: Bool { view == "Frequency" || view == "Positions" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JoinedSegmentedControl(options: modes, selection: $view, title: { $0 })
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Analysis")
                .uiInteractionAnchor("room-analysis-mode")
            if view == "Positions", let session = editor.session {
                WrappingControlLayout {
                    ForEach(Array(session.positions.enumerated()), id: \.element.id) { i, position in
                        Toggle("Position \(i + 1)", isOn: Binding(get: { !hidden.contains(position.id) }, set: { if $0 { hidden.remove(position.id) } else { hidden.insert(position.id) } }))
                    }
                }
            }
            if ["Impulse", "Phase", "Group Delay"].contains(view) && !timingAvailable {
                Text("Timing is not reliable for this recording. Frequency and position analysis remain available.").foregroundStyle(.secondary)
            } else {
                RoomAnalysisPlot(series: series, logarithmic: view != "Impulse", label: view == "Impulse" ? "Time (ms)" : "Frequency (Hz)")
                    .frame(height: 230)
                if ["Impulse", "Phase", "Group Delay"].contains(view), (editor.session?.measurementAnalysisVersion ?? 1) >= 2 {
                    Text("Peak-relative timing; not a speaker-alignment measurement. Unreliable frequencies are omitted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            WrappingControlLayout {
                ForEach(editor.session?.context.topology.endpoints ?? [], id: \.id) { endpoint in
                    channelToggle(endpoint.id.channelIndex, title: endpoint.displayName)
                }
                if supportsSmoothing {
                    Toggle("Smoothed", isOn: $smoothed).toggleStyle(.checkbox)
                        .uiInteractionAnchor("room-analysis-smoothed")
                }
            }.font(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
            WrappingControlLayout {
                HStack(spacing: 14) {
                    Toggle("Reliability overlay", isOn: $reliability).toggleStyle(.checkbox).disabled(view != "Frequency")
                        .uiInteractionAnchor("room-analysis-reliability")
                    if supportsSmoothing {
                        RoomCorrectionMenu(label: "Smoothing:", selection: $smoothing, options: [24, 12, 6, 3], title: { "1/\($0)" }, compact: true)
                            .frame(width: 116).disabled(!smoothed)
                    }
                }
                if editor.comparison != nil { Toggle("Compare previous session", isOn: $comparingSessions) }
            }.font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            if operation.isRunning { ProgressView().controlSize(.small) }
            if editor.session == nil { Text("Measure a listening position to view its response.").foregroundStyle(.secondary) }
        }
        .onAppear { refresh() }
        .onChange(of: editor.revision) { _ in refresh() }
        .onChange(of: view) { _ in refresh() }
        .onChange(of: hiddenChannels) { _ in refresh() }
        .onChange(of: smoothing) { _ in refresh() }
        .onChange(of: smoothed) { _ in refresh() }
        .onChange(of: hidden) { _ in refresh() }
        .onChange(of: reliability) { _ in refresh() }
        .onChange(of: comparingSessions) { _ in refresh() }
        .onDisappear { operation.cancel() }
    }
    private func channelToggle(_ channel: Int, title: String) -> some View {
        Button {
            if hiddenChannels.contains(channel) { hiddenChannels.remove(channel) }
            else { hiddenChannels.insert(channel) }
        } label: {
            Label(title, systemImage: "minus")
                .foregroundStyle(hiddenChannels.contains(channel) ? Color.secondary.opacity(0.4) : roomChannelColor(channel))
        }
        .buttonStyle(.plain)
        .accessibilityValue(hiddenChannels.contains(channel) ? "Hidden" : "Shown")
        .uiInteractionAnchor("room-analysis-channel-\(channel)")
    }
    private func refresh() {
        guard let session = editor.session else { series = []; return }
        let view = view, hiddenChannels = hiddenChannels, smoothed = smoothed, smoothing = smoothing, hidden = hidden, reliability = reliability
        let comparison = comparingSessions ? editor.comparison : nil
        timingAvailable = session.positions.first(where: \.isMain)?.observations
            .filter { !hiddenChannels.contains($0.channel) }
            .contains(where: { observation in
                if view == "Impulse" { return observation.hasUsableImpulse }
                if view == "Group Delay", session.measurementAnalysisVersion >= 2 {
                    return observation.hasUsableRelativeTiming && observation.bins.filter {
                        ($0.timingReliability ?? 0) > 0.4 && $0.groupDelayMS != nil
                    }.count >= 12
                }
                return observation.hasUsableRelativeTiming
            }) == true
        operation.run {
            var result: [RoomPlotSeries] = []
            for (session, previous) in [(session, false), comparison.map { ($0, true) }].compactMap({ $0 }) {
                let positions = view == "Positions" ? session.positions.filter { !hidden.contains($0.id) && !$0.skipped } : Array(session.positions.filter { $0.isMain && !$0.skipped }.prefix(1))
                for position in positions {
                    for observation in position.observations where !hiddenChannels.contains(observation.channel) {
                        try Task.checkCancellation()
                        var points: [SIMD2<Double>] = []
                        if view == "Impulse" {
                            guard observation.hasUsableImpulse else { continue }
                            let strideLength = max(1, observation.impulse.count / 900)
                            // Preserve both extrema of each display bucket so a
                            // narrow direct impulse cannot fall between samples.
                            for start in stride(from: 0, to: observation.impulse.count, by: strideLength) {
                                let range = start..<min(observation.impulse.count, start + strideLength)
                                let low = range.min { observation.impulse[$0] < observation.impulse[$1] } ?? start
                                let high = range.max { observation.impulse[$0] < observation.impulse[$1] } ?? start
                                for index in Set([low, high]).sorted() {
                                    points.append(SIMD2((Double(index) / observation.impulseSampleRate - (observation.impulseTimeZeroSeconds ?? 0)) * 1000,
                                        Double(observation.impulse[index])))
                                }
                            }
                        } else {
                            var previousPhase = 0.0, unwrapped = 0.0, previousFrequency = 0.0
                            for bin in observation.bins {
                                var value = bin.magnitudeDB
                                if view == "Phase" || view == "Group Delay" {
                                    guard observation.hasUsableRelativeTiming else { continue }
                                    guard (bin.timingReliability ?? bin.reliability) > 0.4 else {
                                        points.append(SIMD2(bin.frequency, .nan)); previousFrequency = 0; continue
                                    }
                                    if view == "Group Delay", session.measurementAnalysisVersion >= 2, bin.groupDelayMS == nil {
                                        points.append(SIMD2(bin.frequency, .nan)); previousFrequency = 0; continue
                                    }
                                    if previousFrequency == 0 { previousPhase = bin.phase; unwrapped = bin.phase }
                                    var delta = bin.phase - previousPhase
                                    while delta > .pi { delta -= 2 * .pi }; while delta < -.pi { delta += 2 * .pi }
                                    unwrapped += delta
                                    value = view == "Phase" ? unwrapped : (bin.groupDelayMS ?? (previousFrequency > 0 ? -delta / (2 * .pi * (bin.frequency - previousFrequency)) * 1000 : 0))
                                    previousPhase = bin.phase; previousFrequency = bin.frequency
                                } else if smoothed {
                                    let neighbours = observation.bins.filter { abs(log2($0.frequency / bin.frequency)) <= 0.5 / Double(smoothing) }
                                    value = neighbours.map(\.magnitudeDB).reduce(0, +) / Double(max(1, neighbours.count))
                                }
                                points.append(SIMD2(bin.frequency, value))
                            }
                        }
                        result.append(.init(channel: observation.channel, dashed: previous, points: points))
                        if reliability && view == "Frequency" { result.append(.init(channel: observation.channel, dashed: true, points: observation.bins.map { SIMD2($0.frequency, $0.reliability) })) }
                    }
                }
            }
            return result
        } completion: { result in
            if case .success(let series) = result { self.series = series }
        }
    }
}
private struct RoomAnalysisPlot: View {
    var series: [RoomPlotSeries]
    var logarithmic: Bool
    var label: String
    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let points = series.flatMap(\.points).filter { $0.x.isFinite && $0.y.isFinite && (!logarithmic || $0.x > 0) }
                guard !points.isEmpty else { return }
                func x(_ value: Double) -> Double { logarithmic ? log10(max(1, value)) : value }
                let minX = points.map { x($0.x) }.min()!, maxX = points.map { x($0.x) }.max()!
                let minY = points.map(\.y).min()! - 0.1, maxY = points.map(\.y).max()! + 0.1
                // Tick labels are centered on their grid lines. Inset the plot
                // so the first and last labels stay inside the canvas.
                let plot = CGRect(x: 35, y: 10, width: max(1, size.width - 40), height: max(1, size.height - 20))
                for i in 0...4 {
                    let y = plot.minY + plot.height * Double(i) / 4
                    var line = Path(); line.move(to: .init(x: plot.minX, y: y)); line.addLine(to: .init(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.2)))
                    context.draw(Text((maxY - (maxY - minY) * Double(i) / 4).formatted(.number.precision(.fractionLength(1)))).font(.system(size: 9)), at: .init(x: 15, y: y))
                }
                for line in series {
                    var path = Path()
                    var continuing = false
                    for p in line.points {
                        guard p.x.isFinite, p.y.isFinite, !logarithmic || p.x > 0 else { continuing = false; continue }
                        let point = CGPoint(x: plot.minX + (x(p.x) - minX) / max(0.001, maxX - minX) * plot.width, y: plot.minY + (maxY - p.y) / max(0.001, maxY - minY) * plot.height)
                        if continuing { path.addLine(to: point) } else { path.move(to: point) }
                        continuing = true
                    }
                    context.stroke(path, with: .color(roomChannelColor(line.channel)), style: StrokeStyle(lineWidth: 1.3, dash: line.dashed ? [4, 3] : []))
                }
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.accessibilityLabel("Room measurement \(label) chart")
    }
}
