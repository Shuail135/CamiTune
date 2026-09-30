import SwiftUI

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
            ScrollView(.horizontal, showsIndicators: overflows) {
                content()
                    .background {
                        if contentWidth == nil || height == nil {
                            GeometryReader { contentGeometry in
                                Color.clear
                                    .onAppear { measuredSize = contentGeometry.size }
                                    .onChange(of: contentGeometry.size) { measuredSize = $0 }
                            }
                        }
                    }
                    .fixedSize(horizontal: contentWidth == nil, vertical: true)
                    .frame(width: resolvedWidth, alignment: .leading)
                    .padding(.bottom, 8)
            }
            // Hiding the indicator alone still intercepts trackpad gestures and
            // allows rubber-banding. Keep view identity when resizing so an EQ
            // text field or drag isn't destroyed at the overflow boundary.
            .scrollDisabled(!overflows)
            .scrollBounceWhenNeeded(axes: .horizontal)
        }
        .frame(height: height ?? measuredSize.height + 8)
    }
}
