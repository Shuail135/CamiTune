import SwiftUI

/// Changes navigation placement without replacing the editor or its local state.
struct AdaptiveEditorLayout<Sidebar: View, CompactSelector: View, Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 160
    @ScaledMetric(relativeTo: .body) private var minimumEditorWidth: CGFloat = 400
    @State private var isCompact = true
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var compactSelector: () -> CompactSelector
    @ViewBuilder var content: () -> Content

    var body: some View {
        let compact = isCompact
        ArrangedControls(items: ControlLayoutItems.buildBlock(
            ControlLayoutItems.buildExpression(navigation(compact: compact)),
            ControlLayoutItems.buildExpression(content().frame(maxWidth: .infinity, alignment: .topLeading))
        )) { proposedWidth, _, measure in
            let width = proposedWidth ?? sidebarWidth + minimumEditorWidth + 33
            if compact {
                let selector = measure(0, width, nil)
                let editor = measure(1, width, nil)
                return (CGSize(width: width, height: selector.height + 12 + editor.height), [
                    CGRect(origin: .zero, size: selector),
                    CGRect(x: 0, y: selector.height + 12, width: width, height: editor.height)
                ])
            }
            let sidebar = measure(0, sidebarWidth, nil)
            let editorWidth = max(0, width - sidebarWidth - 33)
            let editor = measure(1, editorWidth, nil)
            return (CGSize(width: width, height: max(sidebar.height, editor.height)), [
                CGRect(origin: .zero, size: sidebar),
                CGRect(x: sidebarWidth + 33, y: 0, width: editorWidth, height: editor.height)
            ])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Group {
            if !compact {
                // Span both columns, even when the editor is shorter than the sidebar.
                Rectangle().fill(Color(.separatorColor))
                    .frame(width: 1)
                    .offset(x: sidebarWidth + 16)
                    .allowsHitTesting(false)
            }
        }, alignment: .leading)
        .background(Group {
            GeometryReader { geometry in
                let needsCompactLayout = geometry.size.width < sidebarWidth + minimumEditorWidth + 33
                Color.clear
                    .onAppear { isCompact = needsCompactLayout }
                    // Publish only a breakpoint crossing, not every pixel of
                    // the sidebar animation or a live window resize.
                    .onChange(of: needsCompactLayout) { isCompact = $0 }
            }
        })
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func navigation(compact: Bool) -> some View {
        if compact { compactSelector() }
        else { sidebar().frame(width: sidebarWidth) }
    }
}

/// Hidden pages retain their native controls and last geometry. Only the selected
/// page is measured, so a live meter cannot lay out every retained editor.
struct SelectedEditorPageLayout {
    var selection: Int
    func callAsFunction(@ControlLayoutItems content: () -> [ControlLayoutItem]) -> ArrangedControls {
        ArrangedControls(items: content(), retainedSelection: selection) { width, count, measure in
            guard (0..<count).contains(selection) else { return (.zero, []) }
            let width = width ?? 600
            let size = measure(selection, width, nil)
            let frames = (0..<count).map { index in
                CGRect(x: 0, y: 0, width: width, height: index == selection ? size.height : 0)
            }
            return (CGSize(width: width, height: size.height), frames)
        }
    }
}
