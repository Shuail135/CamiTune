import SwiftUI
import AppKit

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var controller: DiagnosticsController
    @EnvironmentObject private var commands: MainWindowCommandCoordinator
    @State private var showTests = false
    @State private var copied = false

    init(state: AppState) {
        self.state = state
        _controller = ObservedObject(wrappedValue: state.diagnostics)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("System Diagnostics") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Checks this Mac and the current CamiTune installation without changing audio playback.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Run Diagnostics") { controller.run(SystemDiagnostics.cases(state: state)); copied = false }
                                .disabled(controller.isRunning)
                            Button("Drivers & Components") { commands.settingsCategory = "Drivers & Components" }
                        }
                        ForEach(controller.results.filter { $0.safety == .readOnly }) { result in resultRow(result) }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Advanced Test") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runs isolated simulations for development. Your audio devices, output, and saved profiles are not changed.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Run All Self-Tests") { controller.run(DeveloperSelfTests.cases()); copied = false }
                                .disabled(controller.isRunning)
                            Button("Run Selected") {
                                controller.run(DeveloperSelfTests.cases().filter { controller.selectedTests.contains($0.id) })
                                copied = false
                            }.disabled(controller.isRunning || controller.selectedTests.isEmpty)
                        }
                        ForEach(["Planning & Configuration", "Profiles", "PCM / Timeline", "Runtime Lifecycle", "Runtime Health", "Performance Measurement", "Presentation Publication", "Runtime Plan Authority", "Runtime Plan Differ", "Runtime Coordinator"], id: \.self) { suite in
                            let results = controller.results.filter { $0.suite == suite }
                            HStack {
                                Text(suite)
                                Spacer()
                                Text(results.isEmpty ? "Not run" : "\(results.filter { $0.status == .passed }.count) / \(results.count) passed")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        DisclosureGroup("Show individual tests", isExpanded: $showTests) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(DeveloperSelfTests.cases(), id: \.id) { test in
                                    HStack(alignment: .top) {
                                        Toggle(test.name, isOn: Binding(
                                            get: { controller.selectedTests.contains(test.id) },
                                            set: { if $0 { controller.selectedTests.insert(test.id) } else { controller.selectedTests.remove(test.id) } }))
                                            .labelsHidden().disabled(controller.isRunning)
                                            .accessibilityLabel("Select \(test.name)")
                                        if let result = controller.results.first(where: { $0.id == test.id }) {
                                            resultRow(result)
                                        } else {
                                            Text("\(test.id) · \(test.name)").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }.padding(.top, 8)
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Runtime Coordinator") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.runtimeCoordinatorSummary).font(.caption).textSelection(.enabled)
                        Button("Copy Coordinator Summary") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.runtimeCoordinatorSummary, forType: .string)
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Runtime Plan") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let candidate = state.candidatePlanRevision {
                            Text("Prepared candidate revision: \(candidate.generation)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(state.runtimePlanSummary).font(.caption).textSelection(.enabled)
                        Button("Copy Plan Summary") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.runtimePlanSummary, forType: .string)
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Runtime Plan Diff") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.runtimePlanDiffSummary).font(.caption).textSelection(.enabled)
                        Text("Actual graph update: " + state.actualGraphUpdateSummary)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Compare Current Intent") { Task { await state.inspectRuntimePlanDiff() } }
                                .disabled(!state.isActive || state.transitionInProgress)
                            Button("Copy Diff Summary") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(state.runtimePlanDiffSummary + "\nActual graph update: " + state.actualGraphUpdateSummary, forType: .string)
                            }
                        }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                PerformanceDiagnosticsView(state: state)
                if controller.isRunning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("\(controller.completedCount) of \(controller.totalCount) checks complete")
                        Spacer()
                        Button("Cancel") { controller.cancel() }
                    }
                } else if let date = controller.lastCompletedRun {
                    Text("\(controller.runMessage) · Last run: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(copied ? "Report Copied" : "Copy Diagnostic Report") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(controller.report(), forType: .string)
                    }.disabled(controller.results.isEmpty || controller.isRunning)
                    Button("Clear Results") { controller.clear(); copied = false }
                        .disabled(controller.results.isEmpty || controller.isRunning)
                }
            }
        }
    }

    private func resultRow(_ result: DiagnosticResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(result.status)).foregroundStyle(color(result.status))
                .frame(width: 16).accessibilityLabel(result.status.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name).fontWeight(.medium)
                Text(result.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !result.evidence.isEmpty || result.details != nil {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, item in
                                Text("\(item.name): \(item.value)")
                            }
                            if let details = result.details { Text(details) }
                            Text("Duration: \(String(describing: result.duration))")
                        }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.font(.caption)
                }
            }
            Spacer(minLength: 0)
            Text(result.status.rawValue.capitalized).font(.caption).foregroundStyle(color(result.status))
        }
    }

    private func symbol(_ status: DiagnosticStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .pending, .skipped: return "circle"
        }
    }
    private func color(_ status: DiagnosticStatus) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .running: return .accentColor
        case .pending, .skipped: return .secondary
        }
    }
}
