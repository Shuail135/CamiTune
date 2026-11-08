import Darwin
import Foundation

/// Control/UI deadlines count system sleep, like ContinuousClock. Audio sample
/// clocks and the uptime-based performance recorder keep their own time domains.
enum RuntimeClock {
    static var now: TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    static func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds < Double(Int64.max) / 1_000_000_000 else {
            throw POSIXError(.EINVAL)
        }
        guard seconds > 0 else { return }
        try await ContinuousDeadlineQueue.shared.get().sleep(nanoseconds: Int64((seconds * 1_000_000_000).rounded(.up)))
        try Task.checkCancellation()
    }
}

/// One kernel event queue serves all control deadlines. Mach continuous timers
/// survive sleep and wall-clock changes; cancellation removes the kernel timer.
/// Task.sleep(nanoseconds:) uses uptime on older runtimes and has a different
/// sleep/wake contract, so it cannot replace these deadlines.
private final class ContinuousDeadlineQueue: @unchecked Sendable {
    static let shared = Result { try ContinuousDeadlineQueue() }
    private let queue = DispatchQueue(label: "CamiTune.ControlDeadlines", qos: .userInitiated)
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var nextID: UInt64 = 0
    private var pending: [UInt64: Wait] = [:]

    private final class Wait: @unchecked Sendable {
        // Accessed exclusively on the deadline queue, including cancellation
        // that arrives before the continuation has been installed.
        enum State {
            case pending, cancelled, finished
            case scheduled(UInt64, CheckedContinuation<Void, Error>)
        }
        var state = State.pending
    }

    private init() throws {
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw Self.systemError() }
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }

    func sleep(nanoseconds: Int64) async throws {
        let wait = Wait()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(wait, nanoseconds: nanoseconds, continuation: continuation) }
            }
        } onCancel: {
            self.queue.async { self.cancel(wait) }
        }
    }

    private func start(_ wait: Wait, nanoseconds: Int64, continuation: CheckedContinuation<Void, Error>) {
        if case .cancelled = wait.state {
            wait.state = .finished
            continuation.resume(throwing: CancellationError())
            return
        }
        nextID &+= 1
        let id = nextID
        var event = kevent64_s(ident: id, filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ONESHOT | EV_RECEIPT),
            fflags: UInt32(NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME),
            data: nanoseconds, udata: 0, ext: (0, 0))
        var receipt = kevent64_s()
        var immediate = timespec()
        let count = kevent64(descriptor, &event, 1, &receipt, 1, 0, &immediate)
        guard count == 1, receipt.data == 0 else {
            wait.state = .finished
            continuation.resume(throwing: count < 0 ? Self.systemError() : Self.systemError(Int(receipt.data)))
            return
        }
        wait.state = .scheduled(id, continuation)
        pending[id] = wait
    }

    private func cancel(_ wait: Wait) {
        switch wait.state {
        case .pending: wait.state = .cancelled
        case .scheduled(let id, let continuation):
            pending[id] = nil
            wait.state = .finished
            // An already-fired one-shot may have left the kernel queue. Its
            // pending read is harmless because the wait no longer exists.
            var event = kevent64_s(ident: id, filter: Int16(EVFILT_TIMER),
                flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: 0, ext: (0, 0))
            _ = kevent64(descriptor, &event, 1, nil, 0, 0, nil)
            continuation.resume(throwing: CancellationError())
        case .cancelled, .finished: break
        }
    }

    private func receive() {
        var events = [kevent64_s](repeating: kevent64_s(), count: 64)
        var immediate = timespec()
        let count = kevent64(descriptor, nil, 0, &events, Int32(events.count), 0, &immediate)
        guard count >= 0 else {
            if errno == EINTR { return }
            let error = Self.systemError()
            for wait in Array(pending.values) {
                if case .scheduled(let id, let continuation) = wait.state {
                    pending[id] = nil
                    wait.state = .finished
                    continuation.resume(throwing: error)
                }
            }
            return
        }
        for event in events.prefix(Int(count)) {
            guard let wait = pending.removeValue(forKey: event.ident),
                  case .scheduled(_, let continuation) = wait.state else { continue }
            wait.state = .finished
            if event.flags & UInt16(EV_ERROR) != 0 {
                continuation.resume(throwing: Self.systemError(Int(event.data)))
            } else {
                continuation.resume()
            }
        }
    }

    private static func systemError(_ code: Int = Int(errno)) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: code)
    }
}
