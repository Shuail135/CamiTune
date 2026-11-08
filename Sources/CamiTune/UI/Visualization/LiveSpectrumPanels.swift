import SwiftUI
import Combine
import Foundation

@MainActor
struct LiveSpectrumPanels: View {
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    let graphModel: ProfileEditorGraphModel
    // Retain one shared frame without observing it in the panel layout. Only
    // the graphs observe live values, as the channel meter bars already do.
    @State private var display = SpectrumDisplay()

    var body: some View {
        VisibleRegion { isVisible in
            ResponsiveStackLayout(minimumHorizontalWidth: 540, equalHeight: true) {
                preEQPanel
                postEQPanel
            }
            .onAppear {
                if isVisible { refresh() }
            }
            .onChange(of: isVisible) { if $0 { refresh() } }
            // The analyzer can publish much faster than a pair of 220-point Canvas
            // graphs needs to redraw. Keep analysis at full rate but cap this large
            // profile-header presentation to 10 Hz, using the newest frame.
            .onReceive(
                spectrum.$points.filter { _ in isVisible }.throttle(
                    for: .milliseconds(100),
                    scheduler: DispatchQueue.main,
                    latest: true
                )
            ) { points in
                guard isVisible else { return }
                display.update(spectrum.activeProfileID == profileID
                    ? points
                    : [])
            }
        }
    }

    private func refresh() {
        display.update(spectrum.activeProfileID == profileID ? spectrum.points : [])
    }

    private var spectrumLegend: some View {
        HStack(spacing: 12) {
            Text("post-EQ").foregroundColor(.blue)
            Text("EQ response").foregroundColor(CorrectionGraphPresentation.equalizerColor)
        }.font(.caption)
    }

    private var preEQPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pre-EQ Spectrum").font(.headline)
                spectrumLegend.hidden().accessibilityHidden(true)
                Spacer(minLength: 0)
                LivePreEQSpectrumGraph(display: display)
                    .frame(height: 220)
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, minHeight: 284)
        .uiInteractionAnchor("spectrum-pre-card")
    }

    private var postEQPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Post-EQ Spectrum").font(.headline)
                spectrumLegend
                Spacer(minLength: 0)
                LivePostEQSpectrumGraph(
                    display: display,
                    graphModel: graphModel
                )
                .frame(height: 220)
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, minHeight: 284)
        .uiInteractionAnchor("spectrum-post-card")
    }
}

@MainActor
final class SpectrumDisplay: ObservableObject {
    @Published private(set) var points: [SpectrumPoint] = []

    func update(_ points: [SpectrumPoint]) {
        if self.points != points { self.points = points }
    }
}

private struct LivePreEQSpectrumGraph: View {
    @ObservedObject var display: SpectrumDisplay

    var body: some View {
        LineGraph(
            points: display.points.map { ($0.frequency, $0.db) },
            xRange: 20...20_000,
            yRange: -100...0,
            fillsArea: true,
            usesSpectrumLayout: true
        )
    }
}

private struct LivePostEQSpectrumGraph: View {
    @ObservedObject var display: SpectrumDisplay
    @ObservedObject var graphModel: ProfileEditorGraphModel

    var body: some View {
        let response = graphModel.responsePoints.map { ($0.frequency, $0.gainDB) }
        return SpectrumWithResponseGraph(
            spectrum: outputPoints(response: response),
            response: response,
            xRange: 20...20_000,
            spectrumRange: -100...0,
            responseRange: -12...12
        )
    }

    private func outputPoints(response: [(Double, Double)]) -> [(Double, Double)] {
        guard !response.isEmpty else { return inputPoints }
        let minimumFrequency = response[0].0
        let maximumFrequency = response[response.count - 1].0
        let logSpan = log(maximumFrequency / minimumFrequency)
        return display.points.map { point in
            let position = log(max(point.frequency, minimumFrequency) / minimumFrequency) / logSpan
            let index = min(response.count - 1, max(0, Int(position * Double(response.count - 1))))
            return (point.frequency, min(0, point.db + response[index].1))
        }
    }

    private var inputPoints: [(Double, Double)] {
        display.points.map { ($0.frequency, $0.db) }
    }
}
