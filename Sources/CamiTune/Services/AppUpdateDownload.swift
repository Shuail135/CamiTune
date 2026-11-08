import Foundation

/// The completion callback owns the temporary download until it has moved into
/// the update's directory. Cancellation waits for that callback, so cleanup can
/// never race a late file move from a retired download.
final class AppUpdateDownload {
    private final class Active {
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<URLResponse, Error>
        var observations: [NSKeyValueObservation] = []
        var lastProgress: (written: Int64, expected: Int64)?
        init(task: URLSessionDownloadTask, continuation: CheckedContinuation<URLResponse, Error>) {
            self.task = task; self.continuation = continuation
        }
    }
    private enum State {
        case pending, cancelledBeforeStart, running(Active), cancelling(Active), finished
    }
    private let lock = NSLock()
    private var state = State.pending
    private let destination: URL
    private let progress: (Int64, Int64) -> Void

    private init(destination: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination; self.progress = progress
    }
    static func transfer(_ request: URLRequest, session: URLSession, to destination: URL,
                         progress: @escaping (Int64, Int64) -> Void) async throws -> URLResponse {
        let download = AppUpdateDownload(destination: destination, progress: progress)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(request, session: session, continuation: continuation)
            }
        } onCancel: { download.cancel() }
        try Task.checkCancellation()
        return response
    }

    private func start(_ request: URLRequest, session: URLSession,
                       continuation: CheckedContinuation<URLResponse, Error>) {
        let task = session.downloadTask(with: request) { location, response, error in
            self.finish(location: location, response: response, error: error)
        }
        lock.lock()
        guard case .pending = state else {
            state = .finished
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        let active = Active(task: task, continuation: continuation)
        state = .running(active)
        active.observations = [
            task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] _, _ in self?.publishProgress() },
            task.observe(\.countOfBytesExpectedToReceive, options: [.new]) { [weak self] _, _ in self?.publishProgress() }
        ]
        lock.unlock()
        task.resume()
    }

    private func publishProgress() {
        lock.lock()
        guard case .running(let active) = state else { lock.unlock(); return }
        let value = (written: active.task.countOfBytesReceived, expected: active.task.countOfBytesExpectedToReceive)
        guard active.lastProgress?.written != value.written || active.lastProgress?.expected != value.expected else {
            lock.unlock(); return
        }
        active.lastProgress = value
        lock.unlock()
        progress(value.written, value.expected)
    }

    private func cancel() {
        lock.lock()
        let task: URLSessionDownloadTask?
        switch state {
        case .pending: state = .cancelledBeforeStart; task = nil
        case .running(let active): state = .cancelling(active); task = active.task
        case .cancelledBeforeStart, .cancelling, .finished: task = nil
        }
        lock.unlock()
        task?.cancel()
    }

    private func finish(location: URL?, response: URLResponse?, error: Error?) {
        lock.lock()
        let active: Active
        let cancelled: Bool
        switch state {
        case .running(let value): active = value; cancelled = false
        case .cancelling(let value): active = value; cancelled = true
        default: lock.unlock(); return
        }
        state = .finished
        lock.unlock()
        active.observations.removeAll()
        do {
            if cancelled { throw CancellationError() }
            if let error { throw error }
            guard let location, let response else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            progress(active.task.countOfBytesReceived, active.task.countOfBytesExpectedToReceive)
            active.continuation.resume(returning: response)
        } catch { active.continuation.resume(throwing: error) }
    }
}
