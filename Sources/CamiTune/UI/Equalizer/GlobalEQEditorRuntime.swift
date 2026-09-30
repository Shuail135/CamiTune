import Combine
import Foundation

/// Task handles and mutation guards that do not affect rendering.
/// Keeping them out of @State avoids view invalidations when tasks are replaced.
@MainActor
final class GlobalEQEditorRuntime: ObservableObject {
    var historyActionName: String?
    var historyBaseline: GlobalEQHistoryState?
    var suppressChanges = false
    var liveApplyTask: Task<Void, Never>?
    var filterResponseTask: Task<Void, Never>?
    var headroomCalculationTask: Task<Void, Never>?
    var loadedProfileID: UUID?
    var continuousEditDepth = 0
    var commitPendingAfterContinuousEdit = false

    deinit {
        liveApplyTask?.cancel()
        filterResponseTask?.cancel()
        headroomCalculationTask?.cancel()
    }
}
