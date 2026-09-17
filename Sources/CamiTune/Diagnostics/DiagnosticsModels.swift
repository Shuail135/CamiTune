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
