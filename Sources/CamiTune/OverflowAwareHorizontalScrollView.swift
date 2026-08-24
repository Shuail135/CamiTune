import SwiftUI

struct OverflowAwareHorizontalScrollView<Content: View>: View {
    let contentWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width)
            let resolvedWidth = max(contentWidth, availableWidth)
            ScrollView(.horizontal, showsIndicators: contentWidth > availableWidth + 0.5) {
                content()
                    .frame(width: resolvedWidth, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
        .frame(height: height)
    }
}
