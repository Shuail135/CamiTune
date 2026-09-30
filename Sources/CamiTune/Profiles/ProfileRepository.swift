import CamiTuneAudio
import CamiTuneDomain
import Foundation

/// Disk persistence has its own ordered authority. Autosaves may be replaced
/// before execution; durable operations may not. One utility worker owns I/O.
/// A small lock serializes submission/status, never filesystem work or callbacks.
/// This explicit executor also permits a terminal drain without blocking an actor
/// whose continuation would need the terminating MainActor.
final class ProfileRepository: @unchecked Sendable {
    private struct Request {
        var document: ProfileDocument
        let source: ProfileLibraryRevision
        let kind: ProfilePersistenceKind
        let ticket: ProfilePersistenceTicket
        let submitted: UInt64
    }
    let loadedDocument: ProfileDocument?
    private let url: URL
    private let io: ProfileRepositoryFileIO
    private let lock = NSCondition()
    private let worker = DispatchQueue(label: "CamiTune.ProfileRepository", qos: .utility)
    private var queue: [Request] = []
    private var running = false
    private var sequence: UInt64 = 0
    private var nextRevision: UInt64
    private var newestSource = ProfileLibraryRevision(rawValue: 0)
    private var state = ProfileRepositoryStatus()
    var status: ProfileRepositoryStatus { lock.lock(); defer { lock.unlock() }; return state }

    init(url: URL, io: ProfileRepositoryFileIO = .live) {
        self.url = url; self.io = io
        do { loadedDocument = try io.load(url) }
        catch { loadedDocument = nil; state.protectedStorage = true; state.lastError = "Saved profile storage is unreadable or incompatible." }
        nextRevision = loadedDocument?.documentRevision.rawValue ?? 0
        state.lastCommittedRevision = .init(rawValue: nextRevision)
    }
    /// Acceptance is synchronous and cheap; completion never requires MainActor.
    /// Cancellation of a caller cannot discard an accepted durable transaction.
    func submit(_ document: ProfileDocument, source: ProfileLibraryRevision,
                kind: ProfilePersistenceKind) -> ProfilePersistenceTicket {
        lock.lock()
        sequence += 1
        let ticket = ProfilePersistenceTicket(id: .init(rawValue: sequence))
        if state.protectedStorage {
            lock.unlock(); ticket.finish(.failure(ProfileRepositoryError.protectedStorage)); return ticket
        }
        if kind == .autosave && source < newestSource {
            state.supersededAutosaveCount += 1
            lock.unlock(); ticket.finish(.success(.superseded)); return ticket
        }
        newestSource = max(newestSource, source)
        let removed = queue.filter { $0.kind == .autosave && $0.source <= source }
        queue.removeAll { $0.kind == .autosave && $0.source <= source }
        state.supersededAutosaveCount += UInt64(removed.count)
        queue.append(.init(document: document, source: source, kind: kind, ticket: ticket, submitted: DispatchTime.now().uptimeNanoseconds))
        updatePending()
        let start = !running; running = true
        lock.unlock()
        removed.forEach { $0.ticket.finish(.success(.superseded)) }
        if start { worker.async { self.run() } }
        return ticket
    }
    private func updatePending() {
        state.pendingAutosave = queue.contains { $0.kind == .autosave }
        state.pendingDurableCount = queue.filter { $0.kind != .autosave }.count
    }
    private func run() {
        while true {
            lock.lock()
            guard !queue.isEmpty else {
                running = false; state.inFlightOperation = nil; state.inFlightKind = nil
                state.targetRevision = nil; state.sourceRevision = nil
                lock.broadcast(); lock.unlock(); return
            }
            var request = queue.removeFirst(); nextRevision += 1
            request.document.documentRevision = .init(rawValue: nextRevision)
            request.document.schemaVersion = ProfileDocument.currentSchemaVersion
            state.inFlightOperation = request.ticket.id; state.inFlightKind = request.kind
            state.targetRevision = request.document.documentRevision; state.sourceRevision = request.source
            updatePending(); lock.unlock()
            let writeStarted = PerformanceClock.now()
            let queueMS = Double(writeStarted.rawValue - request.submitted) / 1e6
            let result: Result<ProfileAutosaveResult, Error>
            do {
                let times = try io.persist(request.document, url)
                let receipt = ProfilePersistenceReceipt(operationID: request.ticket.id, kind: request.kind,
                    sourceLibraryRevision: request.source, documentRevision: request.document.documentRevision,
                    completedAt: Date(), submittedAt: .init(rawValue: request.submitted), writeStartedAt: writeStarted,
                    writeCompletedAt: PerformanceClock.now(), queueMilliseconds: queueMS,
                    encodingMilliseconds: times.encodingMilliseconds, writeMilliseconds: times.writeMilliseconds)
                lock.lock(); state.lastCommittedRevision = receipt.documentRevision; state.lastReceipt = receipt; state.lastError = nil; lock.unlock()
                result = .success(.committed(receipt))
            } catch {
                lock.lock(); state.writeFailures += 1; state.lastError = "Profile write failed."; lock.unlock()
                result = .failure(error)
            }
            request.ticket.finish(result)
        }
    }
    /// Termination/diagnostic teardown only. Accepted work never needs MainActor.
    func drainSynchronously() {
        lock.lock(); defer { lock.unlock() }
        while running { lock.wait() }
    }
}

enum ProfileRepositoryError: LocalizedError {
    case protectedStorage
    var errorDescription: String? { "Saved profiles are protected because this version could not read the original document." }
}

final class ProfilePersistenceTicket: @unchecked Sendable {
    let id: ProfilePersistenceOperationID
    private let condition = NSCondition()
    private var result: Result<ProfileAutosaveResult, Error>?
    private var waiters: [CheckedContinuation<Result<ProfileAutosaveResult, Error>, Never>] = []
    init(id: ProfilePersistenceOperationID) { self.id = id }
    func value() async -> Result<ProfileAutosaveResult, Error> {
        await withCheckedContinuation { continuation in
            condition.lock()
            if let result { condition.unlock(); continuation.resume(returning: result) }
            else { waiters.append(continuation); condition.unlock() }
        }
    }
    func finish(_ result: Result<ProfileAutosaveResult, Error>) {
        condition.lock(); precondition(self.result == nil); self.result = result
        let waiting = waiters; waiters.removeAll(); condition.broadcast(); condition.unlock()
        waiting.forEach { $0.resume(returning: result) }
    }
    /// Termination or isolated diagnostic teardown only.
    func waitSynchronously() -> Result<ProfileAutosaveResult, Error> {
        condition.lock(); defer { condition.unlock() }
        while result == nil { condition.wait() }
        return result!
    }
}
