import CamiTuneAudio
import CamiTuneDomain
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct PerformanceDiagnosticsSection: View {
    let state: AppState
    @ObservedObject private var recorder: RuntimePerformanceRecorder
    @State private var expanded = false

    init(state: AppState) {
        self.state = state
        _recorder = ObservedObject(wrappedValue: state.performanceRecorder)
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded { PerformanceDiagnosticsView(state: state) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Performance Recording").font(.headline)
                        .uiInteractionAnchor("diagnostics-performance")
                    Text(recorder.isCapturing ? "Recording in progress. Open to view progress or stop."
                         : recorder.isAggregating ? "Preparing performance report…"
                         : recorder.baseline != nil ? "Recording complete. Open to review or export the report."
                         : "Record timing while reproducing stutters, delays, or slow responses.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}

@MainActor
struct PerformanceDiagnosticsView: View {
    let state: AppState
    @ObservedObject private var recorder: RuntimePerformanceRecorder
    @State private var duration = 30.0
    @State private var detailedTracing = true
    @State private var immediate = false
    @State private var label = ""
    @State private var scenario = "Custom"
    @State private var redactNames = true
    @State private var exportError: String?
    @State private var showReport = false
    @State private var idleEnvironment: PerformanceEnvironment?
    @State private var showOptions = false
    @State private var report = ""
    @State private var preparedReportID: String?
    @StateObject private var exportOperation = UIBackgroundOperation<Bool>()
    private let scenarios = ["Custom", "B1 · One app / Direct / UI hidden", "B2 · One app / Direct / UI visible",
                             "B3 · Several applications", "B4 · Mixed packet sizes", "B5 · Spatial / Reference",
                             "B6 · Other sample rate", "B7 · External CPU workload"]
    private var reportID: String { "\(recorder.baseline?.captureID ?? 0)-\(redactNames)" }
    private var displayedReport: String { preparedReportID == reportID ? report : "" }

    init(state: AppState) {
        self.state = state
        _recorder = ObservedObject(wrappedValue: state.performanceRecorder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measured latency ends at the Camilla input boundary, before physical playback.")
                .font(.caption).foregroundStyle(.secondary)
            if !recorder.isCapturing && !recorder.isAggregating {
                Picker("Duration", selection: $duration) {
                    Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0); Text("60 seconds").tag(60.0)
                }
                DisclosureGroup("Recording Options", isExpanded: $showOptions) {
                    if showOptions {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Scenario", selection: $scenario) { ForEach(scenarios, id: \.self) { Text($0) } }
                            TextField("Capture label", text: $label)
                            Toggle("Detailed audio tracing", isOn: $detailedTracing)
                            if !detailedTracing {
                                Text("Records coarse counters and CPU for an OFF/ON comparison. Phase timing is unavailable.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Immediate (include startup)", isOn: $immediate)
                        }
                    }
                }
                if !immediate { Text("5-second warm-up before measurement.").font(.caption).foregroundStyle(.secondary) }
                Button("Start Capture") {
                    var intended = PerformanceScenario(label: label.isEmpty ? scenario : label)
                    if scenario.hasPrefix("B1") || scenario.hasPrefix("B2") {
                        intended.expectedApplications = 1; intended.expectedSampleRate = 48_000
                        intended.expectedPlaybackMode = PlaybackMode.direct.rawValue
                        intended.expectedProfileVisible = scenario.hasPrefix("B2")
                        intended.expectedWindowVisible = scenario.hasPrefix("B2")
                    }
                    intended.minimumApplications = scenario.hasPrefix("B3") ? 2 : nil
                    intended.requiresMixedPacketSizes = scenario.hasPrefix("B4")
                    intended.requiresNonDirectMode = scenario.hasPrefix("B5")
                    intended.requiresOtherSampleRate = scenario.hasPrefix("B6")
                    let initial = state.performanceEnvironment()
                    recorder.start(options: .init(duration: duration, warmUp: immediate ? 0 : 5,
                        scenario: intended, redactNames: redactNames, detailedAudioTracing: detailedTracing), environment: { [weak state] in
                            state?.performanceEnvironment() ?? initial
                        })
                }
                Text("Set up the workload yourself, then capture. Use Immediate for the first baseline when diagnosing startup queue recoveries.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recorder.isCapturing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(recorder.elapsed < 0 ? String(format: "Warming up… %.1f s", -recorder.elapsed)
                         : String(format: "Capturing… %.1f / %.0f s", recorder.elapsed, recorder.options.duration))
                    Spacer()
                    Button("Stop Capture") { Task { await recorder.stop() } }
                }
                Text("\(recorder.audioCount) PCM samples · \(recorder.packetCount) packet samples · \(recorder.telemetryDrops) telemetry drops")
                    .font(.caption).monospacedDigit()
            } else if recorder.isAggregating {
                ProgressView("Preparing report…").controlSize(.small)
            }
            if let environment = (recorder.isCapturing ? recorder.currentEnvironment : idleEnvironment) ?? recorder.currentEnvironment {
                DisclosureGroup("Audio & Queue Details") {
                    Text("\(environment.sampleRate ?? 0) Hz · \(environment.channelCount ?? 0) channels · \(environment.playbackMode ?? "Inactive") · \(environment.activeApplications) active applications")
                        .font(.caption).foregroundStyle(.secondary)
                    queueView(environment.queue)
                    Text("Session recoveries: \(environment.recoveries) · Dropped PCM frames: \(environment.droppedFrames)").font(.caption).foregroundStyle(.secondary)
                    if !recorder.isCapturing {
                        Button("Refresh Audio Details") { idleEnvironment = state.performanceEnvironment() }
                        Text("Snapshot taken when this section opened or was refreshed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Redact device names and identifiers in exports", isOn: $redactNames).font(.caption)
            if let baseline = recorder.baseline, !recorder.isCapturing, !recorder.isAggregating {
                if baseline.telemetryDrops > 0 {
                    Label("Measurement incomplete: \(baseline.telemetryDrops) telemetry samples dropped", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(baseline.scenarioMismatches, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                Text("\(baseline.recoveriesDuringCapture) recoveries · \(baseline.droppedFramesDuringCapture) frames dropped during capture")
                metricTable("Audio path (ms)", metrics: baseline.audio)
                if let presentation = baseline.presentation {
                    DisclosureGroup("Presentation timing") {
                        if let stats = presentation.statistics {
                            Text("\(stats.requests) requests · \(stats.coalescedRequests) coalesced · \(stats.snapshotsBuilt) builds · \(stats.mainDeliveries) deliveries").font(.caption)
                            Text("Maximum pending drains: \(stats.maximumPendingDrains) · Trailing builds: \(stats.trailingBuilds)").font(.caption).foregroundStyle(.secondary)
                        }
                        metricTable("Presentation (ms)", metrics: presentation.durations)
                    }
                }
                if !baseline.interactions.isEmpty {
                    DisclosureGroup("Interaction timing") { metricTable("Interactions (ms)", metrics: baseline.interactions) }
                }
                if !baseline.transitions.isEmpty {
                    DisclosureGroup("Transition timing") { metricTable("Transitions (ms)", metrics: baseline.transitions) }
                }
                WrappingControlLayout {
                    Button("Copy Performance Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayedReport, forType: .string)
                    }.disabled(displayedReport.isEmpty)
                    Button(exportOperation.isRunning ? "Exporting…" : "Export JSON…") { export(baseline) }
                        .disabled(exportOperation.isRunning)
                }
                DisclosureGroup("Full report and recovery events", isExpanded: $showReport) {
                    if showReport {
                        Text(displayedReport.isEmpty ? "Preparing report…" : displayedReport).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task { idleEnvironment = state.performanceEnvironment() }
        .onChange(of: recorder.isCapturing) { if !$0 { idleEnvironment = state.performanceEnvironment() } }
        .task(id: reportID) {
            report = ""
            preparedReportID = nil
            guard let baseline = recorder.baseline else { return }
            let requestedID = reportID
            let redact = redactNames
            let prepared = await Task.detached(priority: .utility) { baseline.report(redactNames: redact) }.value
            guard !Task.isCancelled else { return }
            report = prepared
            preparedReportID = requestedID
        }
    }
    private func metricTable(_ title: String, metrics: [String: LatencyDistribution]) -> some View {
        OverflowAwareHorizontalScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow { Text(title); Text("Count"); Text("Median"); Text("p95"); Text("p99"); Text("Max") }
                    .fontWeight(.medium)
                ForEach(metrics.keys.sorted(), id: \.self) { name in
                    let distribution = metrics[name]!
                    GridRow {
                        Text(name); Text("\(distribution.sampleCount)")
                        value(distribution.medianMilliseconds); value(distribution.p95Milliseconds)
                        value(distribution.p99Milliseconds); value(distribution.maximumMilliseconds)
                    }
                }
            }.font(.caption).monospacedDigit()
        }
    }
    private func value(_ value: Double) -> some View { Text(String(format: "%.2f", value)) }
    private func queueView(_ queue: PCMQueueSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "Writer queue: %d frames / %.1f ms @ %.0f Hz", queue.queuedFrames, queue.durationMilliseconds, queue.sampleRate))
            Text(String(format: "Session peak: %d frames / %.1f ms · Hard limit: %d frames / %.1f ms", queue.peakQueuedFrames, queue.peakDurationMilliseconds, queue.capacityFrames, queue.capacityMilliseconds))
            if let target = queue.operatingTargetFrames, let recovery = queue.recoveryTargetFrames {
                Text("Configured operating target: \(target) frames · Recovery target: \(recovery) frames")
            }
            if let mode = queue.rateTargetMode {
                Text(mode == .legacyBlockTarget ? "Rate target: legacy per-block reference"
                    : mode == .clockTracked ? "Rate target: fixed, with measured clock drift"
                    : mode == .configuredWhenQueued ? "Rate target: fixed, with empty-queue guard" : "Rate target: fixed configuration")
            }
        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    private func export(_ baseline: PerformanceBaseline) {
        let redact = redactNames
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "CamiTune-performance-\(baseline.captureID).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exportOperation.run {
                try baseline.json(redactNames: redact).write(to: url, options: .atomic)
                return true
            } completion: { result in
                switch result {
                case .success: exportError = nil
                case .failure(let error): exportError = error.localizedDescription
                }
            }
        }
    }
}
