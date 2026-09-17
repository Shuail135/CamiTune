import Foundation

@MainActor
final class DiagnosticsController: ObservableObject {
    @Published private(set) var results: [DiagnosticResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastCompletedRun: Date?
    @Published private(set) var runMessage = ""
    @Published var selectedTests: Set<String> = []
    private var task: Task<Void, Never>?
    private var currentRunIDs: Set<String> = []

    var completedCount: Int { results.filter { currentRunIDs.contains($0.id) && ![.pending, .running].contains($0.status) }.count }
    var totalCount: Int { currentRunIDs.count }

    func waitForCompletion() async { await task?.value }

    func run(_ cases: [DiagnosticCase]) {
        guard !isRunning else { return }
        let safeCases = cases.filter { $0.safety != .disruptive }
        guard !safeCases.isEmpty else { return }
        // Keep the other area’s latest results when one suite is rerun.
        let ids = Set(safeCases.map(\.id))
        currentRunIDs = ids
        results.removeAll { ids.contains($0.id) }
        results += safeCases.map(\.pendingResult)
        isRunning = true
        runMessage = "Running checks…"
        task = Task { [weak self] in
            guard let self else { return }
            for test in safeCases {
                guard !Task.isCancelled else { break }
                guard let index = results.firstIndex(where: { $0.id == test.id }) else { continue }
                results[index].status = .running
                results[index].startedAt = Date()
                let start = ContinuousClock.now
                await Task.yield()
                do {
                    try Task.checkCancellation()
                    let observation = try await test.execute()
                    try Task.checkCancellation()
                    results[index].status = observation.status
                    results[index].summary = observation.summary
                    results[index].evidence = observation.evidence
                    results[index].details = observation.details
                } catch is CancellationError {
                    results[index].status = .skipped
                    results[index].summary = "Cancelled"
                } catch {
                    results[index].status = Task.isCancelled ? .skipped : .failed
                    results[index].summary = Task.isCancelled ? "Cancelled" : error.localizedDescription
                }
                results[index].duration = start.duration(to: .now)
            }
            for index in results.indices where [.pending, .running].contains(results[index].status) {
                results[index].status = .skipped
                results[index].summary = "Cancelled before completion"
            }
            runMessage = Task.isCancelled ? "Run cancelled" : "Run complete"
            lastCompletedRun = Date()
            isRunning = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }
    func clear() {
        guard !isRunning else { return }
        results = []; currentRunIDs = []; lastCompletedRun = nil; runMessage = ""
    }

    func report() -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        var lines = ["CamiTune Diagnostic Report", "CamiTune: \(version)",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Architecture: \(architecture)", "Generated: \(Date().ISO8601Format())",
                     "Run: \(isRunning ? "In progress (partial results)" : runMessage)", ""]
        for suite in Array(Set(results.map(\.suite))).sorted() {
            lines.append(suite)
            for result in results.filter({ $0.suite == suite }) {
                lines.append("[\(result.safety.rawValue)] \(result.id) \(result.name): \(result.status.rawValue.uppercased()) — \(result.summary)")
                lines.append("  Started: \(result.startedAt.ISO8601Format()); duration: \(result.duration)")
                lines += result.evidence.map { "  \($0.name): \($0.value)" }
                if let details = result.details { lines.append("  \(details)") }
            }
            lines.append("")
        }
        return Self.redact(lines.joined(separator: "\n"))
    }

    // Reports deliberately exclude profile documents, app identities, and samples.
    // Scrub filesystem paths even when a parser embeds one in an error message.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
            .replacingOccurrences(of: #"(?:file://)?/(?:Users|Volumes|private|tmp|var)/[^\s\"'\n]+"#,
                                  with: "<path>", options: .regularExpression)
    }
}
