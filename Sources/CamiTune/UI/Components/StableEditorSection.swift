import SwiftUI

/// Preserve section identity and skip unrelated parent updates without inserting
/// a second AppKit hosting tree or caching a dynamic editor's height.
struct StableEditorSection<Revision: Equatable, Content: View>: View {
    let revision: Revision
    @ViewBuilder var content: () -> Content

    var body: some View {
        RevisionedEditorContent(revision: revision, content: content()).equatable()
            .focusSection()
    }
}

private struct RevisionedEditorContent<Revision: Equatable, Content: View>: View, Equatable {
    let revision: Revision
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }
    var body: some View { content }
}
