import SwiftUI

/// Preserve section identity and skip unrelated parent updates without inserting
/// a second AppKit hosting tree or caching a dynamic editor's height.
struct StableEditorSection<Revision: Equatable, Content: View>: View {
    let revision: Revision
    @ViewBuilder var content: () -> Content

    var body: some View {
        RevisionedEditorContent(revision: revision, content: content()).equatable()
            .editorFocusSection()
    }
}

private struct RevisionedEditorContent<Revision: Equatable, Content: View>: View, Equatable {
    let revision: Revision
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }
    var body: some View { content }
}

// A focus section is a routing hint for the newer focus engine. The controls
// themselves always use AppKit's native key-view chain.
extension View {
    @ViewBuilder func editorFocusSection() -> some View {
        if #available(macOS 13, *) { focusSection() }
        else { self }
    }
}
