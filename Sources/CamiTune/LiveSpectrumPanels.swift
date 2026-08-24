import SwiftUI
import Combine
import Foundation

@MainActor
struct LiveSpectrumPanels: View {
    let spectrum: SpectrumAnalyzer
    let profileID: UUID
    @ObservedObject var graphModel: ProfileEditorGraphModel
    @State private var displayedSpectrumPoints: [SpectrumPoint] = []

    var body: some View {
        let graphResponse = graphModel.responsePoints.map {
            ($0.frequency, $0.gainDB)
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                preEQPanel
                postEQPanel(response: graphResponse)
            }
            VStack(alignment: .leading, spacing: 16) {
                preEQPanel
                postEQPanel(response: graphResponse)
            }
        }
        .onAppear {
            displayedSpectrumPoints = spectrum.activeProfileID == profileID
                ? spectrum.points
                : []
        }
        // The analyzer can publish much faster than a pair of 220-point Canvas
        // graphs needs to redraw. Keep analysis at full rate but cap this large
        // profile-header presentation to 10 Hz, using the newest frame.
        .onReceive(
            spectrum.$points.throttle(
                for: .milliseconds(100),
                scheduler: RunLoop.main,
                latest: true
            )
        ) { points in
            displayedSpectrumPoints = spectrum.activeProfileID == profileID
                ? points
                : []
        }
    }

    private var preEQPanel: some View {
        GroupBox {
            VStack(alignment: .leading) {
                Text("Pre-EQ Spectrum").font(.headline)
                LivePreEQSpectrumGraph(points: displayedSpectrumPoints)
                    .frame(height: 220)
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, minHeight: 284)
    }

    private func postEQPanel(response: [(Double, Double)]) -> some View {
        GroupBox {
            VStack(alignment: .leading) {
                Text("Estimated Post-Global EQ Spectrum").font(.headline)
                HStack(spacing: 12) {
                    Text("post-EQ").foregroundStyle(.green)
                    Text("EQ response").foregroundStyle(.blue)
                }
                .font(.caption)
                LivePostEQSpectrumGraph(
                    points: displayedSpectrumPoints,
                    response: response
                )
                .frame(height: 220)
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, minHeight: 284)
    }
}

private struct LivePreEQSpectrumGraph: View {
    let points: [SpectrumPoint]

    var body: some View {
        LineGraph(
            points: points.map { ($0.frequency, $0.db) },
            xRange: 20...20_000,
            yRange: -100...0,
            fillsArea: true
        )
    }
}

private struct LivePostEQSpectrumGraph: View {
    let points: [SpectrumPoint]
    let response: [(Double, Double)]

    var body: some View {
        SpectrumWithResponseGraph(
            spectrum: outputPoints,
            response: response,
            xRange: 20...20_000,
            spectrumRange: -100...0,
            responseRange: -12...12
        )
    }

    private var outputPoints: [(Double, Double)] {
        guard !response.isEmpty else { return inputPoints }
        let minimumFrequency = response[0].0
        let maximumFrequency = response[response.count - 1].0
        let logSpan = log(maximumFrequency / minimumFrequency)
        return points.map { point in
            let position = log(max(point.frequency, minimumFrequency) / minimumFrequency) / logSpan
            let index = min(response.count - 1, max(0, Int(position * Double(response.count - 1))))
            return (point.frequency, min(0, point.db + response[index].1))
        }
    }

    private var inputPoints: [(Double, Double)] {
        points.map { ($0.frequency, $0.db) }
    }
}
