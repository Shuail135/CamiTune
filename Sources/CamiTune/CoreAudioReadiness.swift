import Foundation

struct CoreAudioWaitResult: Sendable, Equatable {
    enum Source: String, Sendable { case immediate, notification, fallback, timedOut, cancelled }
    let source: Source
    let milliseconds: Double
}

/// No HAL calls under locks. Each event is a hint: freshly recheck the condition.
/// AsyncStream cancellation wakes the consumer, and defer removes every token.
enum CoreAudioConditionWaiter {
    enum Wake: Sendable { case notification, fallback, deadline, cancelled }
    static func wait(
        backend: CoreAudioHALBackend, event: CoreAudioEvent, timeout: Duration,
        condition: @escaping @Sendable () -> Bool,
        mutation: (@Sendable () throws -> Void)? = nil
    ) async throws -> CoreAudioWaitResult {
        let start = ContinuousClock.now
        func result(_ source: CoreAudioWaitResult.Source) -> CoreAudioWaitResult {
            let elapsed = start.duration(to: .now).components
            return .init(source: source, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        try Task.checkCancellation()
        if condition() { return result(.immediate) }
        let (stream, continuation) = AsyncStream<Wake>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let listener = backend.subscribe(event) { continuation.yield(.notification) }
        let fallback = backend.schedule(timeout / 2) { continuation.yield(.fallback) }
        let deadline = backend.schedule(timeout) { continuation.yield(.deadline); continuation.finish() }
        defer { listener?.cancel(); fallback.cancel(); deadline.cancel(); continuation.finish() }
        try Task.checkCancellation()
        // This closes the check/subscribe race even when the event was lost.
        if condition() { return result(.immediate) }
        try mutation?()
        if condition() { return result(.immediate) }
        for await wake in stream {
            try Task.checkCancellation()
            if condition() { return result(wake == .notification ? .notification : .fallback) }
            if wake == .deadline { return result(.timedOut) }
        }
        throw CancellationError()
    }
}

/// The existing endpoint publication transaction is synchronous on a worker.
/// Keep that transaction atomic, but wake visibility checks from HAL events.
/// The same injected clock/event seam makes its timing deterministic in tests.
extension CoreAudioConditionWaiter {
    private final class Signal: @unchecked Sendable {
        let condition = NSCondition()
        var revision: UInt64 = 0
        var source: Wake = .notification
        var expired = false
        func wake(_ value: Wake) {
            condition.lock()
            if !expired { revision &+= 1; source = value; expired = value == .deadline || value == .cancelled }
            condition.broadcast(); condition.unlock()
        }
        func snapshot() -> (UInt64, Wake, Bool) {
            condition.lock(); defer { condition.unlock() }; return (revision, source, expired)
        }
        func awaitChange(after revision: UInt64) {
            condition.lock(); defer { condition.unlock() }
            while self.revision == revision && !expired { condition.wait() }
        }
    }
    static func waitSynchronously(backend: CoreAudioHALBackend, event: CoreAudioEvent,
                                  timeout: Duration, condition: @escaping @Sendable () -> Bool) -> CoreAudioWaitResult {
        let start = ContinuousClock.now
        func result(_ source: CoreAudioWaitResult.Source) -> CoreAudioWaitResult {
            let elapsed = start.duration(to: .now).components
            return .init(source: source, milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        if condition() { return result(.immediate) }
        let signal = Signal()
        let cancellation = CoreAudioPublicationCancellation.current?.observe { signal.wake(.cancelled) }
        let listener = backend.subscribe(event) { signal.wake(.notification) }
        let fallback = backend.schedule(timeout / 2) { signal.wake(.fallback) }
        let deadline = backend.schedule(timeout) { signal.wake(.deadline) }
        defer { listener?.cancel(); fallback.cancel(); deadline.cancel(); cancellation?.cancel() }
        // Capture the event revision before checking so a racing notification
        // between the read and condition.wait cannot be lost.
        var first = true
        while true {
            let (revision, source, expired) = signal.snapshot()
            if source == .cancelled { return result(.cancelled) }
            if condition() { return result(first ? .immediate : (source == .notification ? .notification : .fallback)) }
            if expired { return result(.timedOut) }
            first = false
            signal.awaitChange(after: revision)
        }
    }
}

final class CoreAudioWaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CoreAudioWaitResult] = []
    func append(_ result: CoreAudioWaitResult) { lock.withLock { results.append(result) } }
    var values: [CoreAudioWaitResult] { lock.withLock { results } }
}

/// Publication cancellation wakes its current condition immediately. The publisher
/// disables this scope only while rolling back already-sent external effects.
final class CoreAudioPublicationCancellation: @unchecked Sendable {
    @TaskLocal static var current: CoreAudioPublicationCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    func observe(_ action: @escaping @Sendable () -> Void) -> CoreAudioListenerToken {
        let id = UUID()
        let call = lock.withLock { if cancelled { return true }; observers[id] = action; return false }
        if call { action() }
        return CoreAudioListenerToken { [weak self] in self?.remove(id) }
    }
    private func remove(_ id: UUID) { lock.withLock { _ = observers.removeValue(forKey: id) } }
    func cancel() {
        let actions = lock.withLock { cancelled = true; return Array(observers.values) }
        actions.forEach { $0() }
    }
}
