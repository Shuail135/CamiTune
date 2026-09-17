import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    private let scenarios = ["Custom", "B1 · One app / Direct / UI hidden", "B2 · One app / Direct / UI visible",
                             "B3 · Several applications", "B4 · Mixed packet sizes", "B5 · Spatial / Reference",
                             "B6 · Other sample rate", "B7 · External CPU workload"]

    init(state: AppState) {
        self.state = state
        _recorder = ObservedObject(wrappedValue: state.performanceRecorder)
    }
    var body: some View {
        GroupBox("Performance") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Captures timing observations without changing playback. Capture continues when this page or window is hidden.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Measured latency ends at the Camilla input boundary, before physical playback.")
                    .font(.caption).foregroundStyle(.secondary)
                if !recorder.isCapturing && !recorder.isAggregating {
                    Picker("Scenario", selection: $scenario) { ForEach(scenarios, id: \.self) { Text($0) } }
                    TextField("Capture label", text: $label)
                    Toggle("Detailed audio tracing", isOn: $detailedTracing)
                    if !detailedTracing { Text("Records coarse counters and CPU for an OFF/ON comparison. Phase timing is unavailable.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Picker("Duration", selection: $duration) {
                            Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0); Text("60 seconds").tag(60.0)
                        }
                        Toggle("Immediate (include startup)", isOn: $immediate)
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
                    Text("\(environment.sampleRate ?? 0) Hz · \(environment.channelCount ?? 0) channels · \(environment.playbackMode ?? "Inactive") · \(environment.activeApplications) active applications")
                        .font(.caption).foregroundStyle(.secondary)
                    queueView(environment.queue)
                    Text("Session recoveries: \(environment.recoveries) · Dropped PCM frames: \(environment.droppedFrames)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Redact device names and identifiers in exports", isOn: $redactNames).font(.caption)
                if let baseline = recorder.baseline {
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
                    HStack {
                        Button("Copy Performance Report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(baseline.report(redactNames: redactNames), forType: .string)
                        }
                        Button("Export JSON…") { export(baseline) }
                    }
                    DisclosureGroup("Full report and recovery events", isExpanded: $showReport) {
                        Text(baseline.report(redactNames: redactNames)).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                if !recorder.isCapturing { idleEnvironment = state.performanceEnvironment() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func metricTable(_ title: String, metrics: [String: LatencyDistribution]) -> some View {
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
    private func value(_ value: Double) -> some View { Text(String(format: "%.2f", value)) }
    private func queueView(_ queue: PCMQueueSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "Writer queue: %d frames / %.1f ms @ %.0f Hz", queue.queuedFrames, queue.durationMilliseconds, queue.sampleRate))
            Text(String(format: "Session peak: %d frames / %.1f ms · Capacity: %d frames / %.1f ms", queue.peakQueuedFrames, queue.peakDurationMilliseconds, queue.capacityFrames, queue.capacityMilliseconds))
        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
    private func export(_ baseline: PerformanceBaseline) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "CamiTune-performance-\(baseline.captureID).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try baseline.json(redactNames: redactNames).write(to: url, options: .atomic); exportError = nil }
            catch { exportError = error.localizedDescription }
        }
    }
}
