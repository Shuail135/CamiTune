import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct DiagnosticsView: View {
    // Live audio publications must not invalidate the entire settings page.
    let state: AppState
    @ObservedObject private var controller: DiagnosticsController
    @State private var showRuntime = false
    @State private var showTests = false
    @State private var exporting = false
    @State private var exportError: String?
    @StateObject private var exportOperation = UIBackgroundOperation<Bool>()

    init(state: AppState) {
        self.state = state
        _controller = ObservedObject(wrappedValue: state.diagnostics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Keep progress, cancellation and downloads visible while scrolling.
            WrappingControlLayout {
                Button(exporting ? "Downloading…" : "Download Diagnostic Report…") { downloadReport() }
                    .disabled(controller.results.isEmpty || controller.isRunning || exporting)
                Button("Clear Results") { controller.clear() }
                    .disabled(controller.results.isEmpty || controller.isRunning || exporting)
            }
            if controller.isRunning {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(controller.completedCount) of \(controller.totalCount) checks complete")
                            .font(.callout).monospacedDigit()
                        ProgressView(value: Double(controller.completedCount), total: Double(max(1, controller.totalCount)))
                    }
                    Button("Cancel") { controller.cancel() }
                }
            } else if let date = controller.lastCompletedRun {
                Text("\(controller.runMessage) · Last run: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PerformanceDiagnosticsSection(state: state)
                    GroupBox {
                        DisclosureGroup(isExpanded: $showRuntime) {
                            if showRuntime { DiagnosticsRuntimeView(state: state) }
                        } label: {
                            sectionLabel("Runtime Details", subtitle: "Inspect audio routing and engine snapshots for troubleshooting.",
                                         anchor: "diagnostics-runtime")
                        }
                        .padding(6)
                    }
                    GroupBox {
                        DisclosureGroup(isExpanded: $showTests) {
                            if showTests { DiagnosticsSelfTestsView(controller: controller) }
                        } label: {
                            let summary = DiagnosticResultsSummary(results: controller.results.filter { $0.safety == .simulated })
                            sectionLabel("Developer Self-Tests", subtitle: summary.total == 0
                                ? "Isolated simulations for development and support." : summary.detail,
                                         anchor: "diagnostics-self-tests")
                        }
                        .padding(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .scrollBounceWhenNeeded()
        }
        .disclosureGroupStyle(SectionDisclosureStyle())
        .alert("Couldn’t Download Diagnostic Report", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(exportError ?? "")
            }
    }

    private func downloadReport() {
        let panel = NSSavePanel()
        panel.title = "Download Diagnostic Report"
        panel.prompt = "Download"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "CamiTune-diagnostic-report.txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let report = controller.report()
        exporting = true
        exportError = nil
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                exporting = false
                return
            }
            exportOperation.run {
                try report.write(to: url, atomically: true, encoding: .utf8)
                return true
            } completion: { result in
                exporting = false
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func sectionLabel(_ title: String, subtitle: String, anchor: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).uiInteractionAnchor(anchor)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct DiagnosticResultRow: View {
    let result: DiagnosticResult
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(result.name).fontWeight(.medium)
                Text(result.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !result.evidence.isEmpty || result.details != nil {
                    DisclosureGroup("Details", isExpanded: $expanded) {
                        if expanded {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.name): \(item.value)")
                                }
                                if let details = result.details { Text(details) }
                                Text("Duration: \(String(describing: result.duration))")
                            }.foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(result.status == .skipped ? "Not checked" : result.status.rawValue.capitalized)
                .font(.caption).foregroundStyle(color)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch result.status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .pending, .skipped: return "minus.circle"
        }
    }

    private var color: Color {
        switch result.status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .running: return .accentColor
        case .pending, .skipped: return .secondary
        }
    }
}

@MainActor
private struct DiagnosticsSelfTestsView: View {
    @ObservedObject var controller: DiagnosticsController
    // Build the catalog once, only after opening developer tools.
    @State private var suites: [DiagnosticTestSuite] = []

    var body: some View {
        let results = Dictionary(uniqueKeysWithValues: controller.results.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 12) {
            WrappingControlLayout {
                Button("Run All Self-Tests") { controller.run(suites.flatMap(\.tests)) }
                    .disabled(controller.isRunning || suites.isEmpty)
                Button("Run Selected (\(controller.selectedTests.count))") {
                    controller.run(suites.flatMap(\.tests).filter { controller.selectedTests.contains($0.id) })
                }.disabled(controller.isRunning || controller.selectedTests.isEmpty)
            }
            ForEach(suites) { suite in
                DiagnosticsTestSuiteView(suite: suite, controller: controller, results: results)
            }
        }
        .task {
            guard suites.isEmpty else { return }
            let tests = DeveloperSelfTests.cases()
            let grouped = Dictionary(grouping: tests, by: \.suite)
            suites = grouped.keys.sorted().map { .init(name: $0, tests: grouped[$0] ?? []) }
        }
    }
}

private struct DiagnosticTestSuite: Identifiable {
    let name: String
    let tests: [DiagnosticCase]
    var id: String { name }
}

@MainActor
private struct DiagnosticsTestSuiteView: View {
    let suite: DiagnosticTestSuite
    @ObservedObject var controller: DiagnosticsController
    let results: [String: DiagnosticResult]
    @State private var expanded = false

    var body: some View {
        let summary = DiagnosticResultsSummary(results: suite.tests.compactMap { results[$0.id] })
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(suite.tests, id: \.id) { test in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("Select \(test.name)", isOn: Binding(
                                get: { controller.selectedTests.contains(test.id) },
                                set: { if $0 { controller.selectedTests.insert(test.id) } else { controller.selectedTests.remove(test.id) } }))
                                .labelsHidden().disabled(controller.isRunning)
                                .accessibilityLabel("Select \(test.name)")
                            if let result = results[test.id] { DiagnosticResultRow(result: result) }
                            else { Text(test.name).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(suite.name).fontWeight(.medium)
                Text("\(summary.total) of \(suite.tests.count) tests have results · \(summary.total == 0 ? "Not run" : summary.detail)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct DiagnosticsRuntimeView: View {
    @ObservedObject var state: AppState
    @State private var section = "Runtime Coordinator"
    @State private var snapshot = ""
    @State private var updatedAt: Date?
    @State private var comparing = false
    private let sections = ["Runtime Coordinator", "Timeline Mixer", "Profile Repository",
                            "CoreAudio & Volume Handoff", "Runtime Plan", "Runtime Plan Diff"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Details", selection: $section) {
                ForEach(sections, id: \.self) { Text($0).tag($0) }
            }
            WrappingControlLayout {
                Button("Refresh") { refresh() }
                Button("Copy Snapshot") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(section + "\n" + snapshot, forType: .string)
                }.disabled(snapshot.isEmpty)
                if section == "Runtime Plan Diff" {
                    Button(comparing ? "Comparing…" : "Compare Current Intent") {
                        comparing = true
                        Task {
                            await state.inspectRuntimePlanDiff()
                            refresh()
                            comparing = false
                        }
                    }.disabled(comparing || !state.isActive || state.transitionInProgress)
                }
            }
            if let updatedAt {
                Text("Snapshot: \(updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(snapshot).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: section) { refresh() }
    }

    private func refresh() {
        switch section {
        case "Timeline Mixer":
            snapshot = state.perAppAudio.timelineStatisticsSnapshot().map { $0.summary + "\n\nReorder policy\n" + $0.policySummary }
                ?? "Mixer is processing audio; snapshot unavailable. Choose Refresh to try again."
        case "Profile Repository": snapshot = state.profiles.repositorySummary
        case "CoreAudio & Volume Handoff":
            snapshot = state.coreAudioSummary + "\n" + state.runtimeCoordinator.bindingSummary + "\n" + state.volumeHandoffSummary
        case "Runtime Plan":
            snapshot = (state.candidatePlanRevision.map { "Prepared candidate revision: \($0.generation)\n" } ?? "") + state.runtimePlanSummary
        case "Runtime Plan Diff": snapshot = state.runtimePlanDiffSummary + "\nActual graph update: " + state.actualGraphUpdateSummary
        default: snapshot = state.runtimeCoordinatorSummary
        }
        updatedAt = Date()
    }
}
