import SwiftUI
import AppKit

/// Undo labels and gesture bookkeeping must not invalidate the entire window.
struct HistoryReplayInteractionGate: ViewModifier {
    let history: UndoCoordinator
    @State private var replaying = false
    func body(content: Content) -> some View {
        content.disabled(replaying)
            .onReceive(history.$isReplaying.removeDuplicates()) { replaying = $0 }
    }
}

