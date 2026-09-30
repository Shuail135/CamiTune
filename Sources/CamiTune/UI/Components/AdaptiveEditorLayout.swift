import SwiftUI

/// Changes navigation placement without replacing the editor or its local state.
struct AdaptiveEditorLayout<Sidebar: View, CompactSelector: View, Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 160
    @ScaledMetric(relativeTo: .body) private var minimumEditorWidth: CGFloat = 400
    @State private var availableWidth: CGFloat = 0
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var compactSelector: () -> CompactSelector
    @ViewBuilder var content: () -> Content

    var body: some View {
        let compact = availableWidth < sidebarWidth + minimumEditorWidth + 33
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 33))
        layout {
            Group {
                if compact {
                    compactSelector()
                } else {
                    sidebar().frame(width: sidebarWidth)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) {
                    if !compact {
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                            .offset(x: -17)
                            .allowsHitTesting(false)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { availableWidth = $0 }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Retain an editor's native controls and local drafts without measuring hidden
/// pages on every selection/disclosure change. Hidden pages keep their last
/// geometry; only the selected page determines the surrounding card's size.
struct SelectedEditorPageLayout: Layout {
    var selection: Int
    struct Cache { var sizes: [Int: CGSize] = [:] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}
    // This container uses top-leading placement, not child baseline guides.
    // The default implementations place every retained page again to derive
    // those guides, multiplying layout work whenever live meters update.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.indices.contains(selection) else { return .zero }
        // SwiftUI probes zero and infinite widths before its actual proposal.
        // Never store those probes as geometry for a retained native editor.
        if proposal.width == 0 { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? cache.sizes[selection]?.width ?? 600
        let measured = subviews[selection].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let size = CGSize(width: width, height: measured.height.isFinite ? max(0, measured.height) : 0)
        if proposal.width?.isFinite == true { cache.sizes[selection] = size }
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard bounds.width.isFinite, bounds.height.isFinite else { return }
        for index in subviews.indices {
            let size = index == selection ? bounds.size : cache.sizes[index] ?? CGSize(width: bounds.width, height: 0)
            subviews[index].place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height))
        }
    }
}
