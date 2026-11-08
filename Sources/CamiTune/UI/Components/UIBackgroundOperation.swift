import Combine
import Foundation
import SwiftUI

/// Runs expensive synchronous UI work off-main and discards superseded results.
@MainActor
final class UIBackgroundOperation<Value: Sendable>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var task: Task<Void, Never>? {
        willSet { objectWillChange.send() }
    }
    var isRunning: Bool { task != nil }

    func run(_ work: @escaping @Sendable () throws -> Value,
             completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        cancel()
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
            // Replacement cancels the owning task. Even a synchronous worker
            // that ignores cancellation cannot apply its retired result.
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            completion(result)
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
    }

    deinit { task?.cancel() }
}

/// Owns an asynchronous view effect across identity changes and disappearance.
/// Retained hidden editors cannot restart work when their input changes.
@MainActor
private final class ViewTaskOwner<ID: Equatable>: ObservableObject {
    private enum State {
        case hidden
        case visible(Task<Void, Never>?)
    }
    private struct Request {
        let id: ID
        let action: @MainActor () async -> Void
    }
    private var state = State.hidden
    private var request: Request?

    func update(id: ID, action: @escaping @MainActor () async -> Void) {
        let changed = request?.id != id
        request = Request(id: id, action: action)
        if case .visible = state, changed { appear() }
    }

    func appear() {
        disappear()
        state = .visible(request.map { request in Task { await request.action() } })
    }

    func disappear() {
        if case .visible(let task) = state { task?.cancel() }
        state = .hidden
    }

    deinit {
        if case .visible(let task) = state { task?.cancel() }
    }
}

private struct ViewTaskModifier<ID: Equatable>: ViewModifier {
    let id: ID
    let action: @MainActor () async -> Void
    @StateObject private var owner = ViewTaskOwner<ID>()

    func body(content: Content) -> some View {
        content
            .background(ViewTaskUpdate(id: id, action: action, owner: owner).allowsHitTesting(false))
            .onAppear { owner.appear() }
            .onDisappear { owner.disappear() }
    }
}

/// Native updates receive the current view's closure. SwiftUI's onChange can
/// call the previous view value's closure, which would restart a stale request.
private struct ViewTaskUpdate<ID: Equatable>: NSViewRepresentable {
    let id: ID
    let action: @MainActor () async -> Void
    let owner: ViewTaskOwner<ID>

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { owner.update(id: id, action: action) }
}

extension View {
    func viewTask<ID: Equatable>(id: ID, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(ViewTaskModifier(id: id, action: action))
    }

    func viewTask(_ action: @escaping @MainActor () async -> Void) -> some View {
        viewTask(id: false, action)
    }
}
