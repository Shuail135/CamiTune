import Combine
import Foundation

/// Runs expensive synchronous UI work off-main and discards superseded results.
@MainActor
final class UIBackgroundOperation<Value: Sendable>: ObservableObject {
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    func run(_ work: @escaping @Sendable () throws -> Value,
             completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        cancel()
        let id = UUID()
        requestID = id
        isRunning = true
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try work()
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.task = nil
            self.requestID = nil
            self.isRunning = false
            completion(result)
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        if isRunning { isRunning = false }
    }

    deinit { task?.cancel() }
}
