import SwiftUI
import AppKit

struct OverflowAwareHorizontalScrollView<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    /// Supply known dimensions for fixed EQ strips. Tables can measure their
    /// intrinsic size by leaving these nil, without imposing a page-wide width.
    var contentWidth: CGFloat? = nil
    var height: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @State private var measuredSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width)
            let intrinsicWidth = contentWidth ?? measuredSize.width
            let resolvedWidth = max(intrinsicWidth, availableWidth)
            let overflows = intrinsicWidth > availableWidth + 1 / max(1, displayScale)
            HorizontalEditorScrollView(contentWidth: resolvedWidth, overflows: overflows) {
                content()
                    .background(Group {
                        if contentWidth == nil || height == nil {
                            GeometryReader { contentGeometry in
                                Color.clear
                                    .onAppear { measuredSize = contentGeometry.size }
                                    .onChange(of: contentGeometry.size) { measuredSize = $0 }
                            }
                        }
                    })
                    .fixedSize(horizontal: contentWidth == nil, vertical: true)
                    .frame(width: resolvedWidth, alignment: .leading)
                    .padding(.bottom, 8)
            }
            // Hiding the indicator alone still intercepts trackpad gestures and
            // allows rubber-banding. Keep view identity when resizing so an EQ
            // text field or drag isn't destroyed at the overflow boundary.

        }
        .frame(height: height ?? measuredSize.height + 8)
    }
}

private struct HorizontalEditorScrollView<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let overflows: Bool
    @ViewBuilder var content: () -> Content
    func makeNSView(context: Context) -> EditorScrollView {
        let scroll = EditorScrollView()
        // The scroll viewport and editor width already determine this host's
        // frame. Automatic min/ideal/max probes would lay out every EQ control
        // again whenever a band value or the available width changes.
        if #available(macOS 13, *) { scroll.host.sizingOptions = [] }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = scroll.host
        return scroll
    }
    func updateNSView(_ scroll: EditorScrollView, context: Context) {
        scroll.host.rootView = AnyView(content().environment(\.self, context.environment))
        scroll.editorWidth = contentWidth
        scroll.overflows = overflows
        scroll.hasHorizontalScroller = overflows
        scroll.horizontalScrollElasticity = overflows ? .automatic : .none
        scroll.needsLayout = true
    }
}

private final class EditorScrollView: NSScrollView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var editorWidth: CGFloat = 0
    var overflows = false
    override func layout() {
        super.layout()
        host.frame = NSRect(x: 0, y: 0, width: editorWidth, height: contentSize.height)
        if !overflows && contentView.bounds.origin != .zero {
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if !overflows || (abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) && !event.modifierFlags.contains(.shift)) {
            nextResponder?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}
