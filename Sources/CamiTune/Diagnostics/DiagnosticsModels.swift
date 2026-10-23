import Foundation

enum DiagnosticStatus: String, Sendable {
    case pending, running, passed, warning, failed, skipped
}

enum DiagnosticSafety: String, Sendable {
    case readOnly, simulated, disruptive
}

struct DiagnosticEvidence: Sendable {
    let name: String
    let value: String
}

struct DiagnosticResult: Identifiable, Sendable {
    let id: String
    let suite: String
    let name: String
    let safety: DiagnosticSafety
    var status: DiagnosticStatus
    var summary: String
    var details: String?
    var startedAt = Date()
    var duration: Duration = .zero
    var evidence: [DiagnosticEvidence] = []
}

/// A partial or cancelled run must never be presented as an all-clear.
struct DiagnosticResultsSummary {
    let total: Int
    let passed: Int
    let needsAttention: Int
    let skipped: Int
    let remaining: Int

    init(results: [DiagnosticResult]) {
        total = results.count
        passed = results.filter { $0.status == .passed }.count
        needsAttention = results.filter { $0.status == .failed || $0.status == .warning }.count
        skipped = results.filter { $0.status == .skipped }.count
        remaining = results.filter { $0.status == .pending || $0.status == .running }.count
    }

    var title: String {
        if total == 0 { return "Ready to check" }
        if needsAttention > 0 { return "\(needsAttention) \(needsAttention == 1 ? "check needs" : "checks need") attention" }
        if remaining > 0 { return "Checking your system…" }
        if skipped > 0 { return "Some checks could not run" }
        return "All system checks passed"
    }

    var detail: String {
        var parts = ["\(passed) passed"]
        if needsAttention > 0 { parts.append("\(needsAttention) \(needsAttention == 1 ? "needs" : "need") attention") }
        if skipped > 0 { parts.append("\(skipped) not checked") }
        if remaining > 0 { parts.append("\(remaining) remaining") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct DiagnosticCase {
    let id: String
    let suite: String
    let name: String
    let safety: DiagnosticSafety
    let run: @MainActor () async throws -> DiagnosticObservation

    var pendingResult: DiagnosticResult {
        DiagnosticResult(id: id, suite: suite, name: name, safety: safety,
                         status: .pending, summary: "Waiting to run")
    }
}

struct DiagnosticObservation: Sendable {
    var status: DiagnosticStatus = .passed
    var summary: String
    var evidence: [DiagnosticEvidence] = []
    var details: String? = nil
}

struct DiagnosticFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func diagnosticRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DiagnosticFailure(message: message) }
}

extension DiagnosticCase {
    /// Watchdog only: timing-sensitive tests use explicit gates and synthetic dates.
    /// Structured cancellation drains the case and its sandbox before returning.
    func execute() async throws -> DiagnosticObservation {
        try await withThrowingTaskGroup(of: DiagnosticObservation.self) { group in
            group.addTask { @MainActor in try await run() }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw DiagnosticFailure(message: "Check exceeded its 15-second deadline")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
