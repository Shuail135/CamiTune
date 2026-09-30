import SwiftUI

/// Selects a layout using the offered width without constructing and measuring
/// duplicate control trees. Children keep their identity across the breakpoint.
struct ResponsiveStackLayout: Layout {
    var minimumHorizontalWidth: CGFloat
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 16
    var centered = false
    var equalHeight = false

    struct Cache {
        var horizontal: AnyLayout.Cache
        var vertical: AnyLayout.Cache
    }
    private var horizontal: AnyLayout { AnyLayout(HStackLayout(alignment: .top, spacing: horizontalSpacing)) }
    private var vertical: AnyLayout { AnyLayout(VStackLayout(alignment: centered ? .center : .leading, spacing: verticalSpacing)) }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(horizontal: horizontal.makeCache(subviews: subviews), vertical: vertical.makeCache(subviews: subviews))
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        horizontal.updateCache(&cache.horizontal, subviews: subviews)
        vertical.updateCache(&cache.vertical, subviews: subviews)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let proposal = ProposedViewSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil },
            height: proposal.height.flatMap { $0.isFinite ? $0 : nil })
        if (proposal.width ?? .infinity) >= minimumHorizontalWidth {
            if equalHeight, let width = proposal.width, !subviews.isEmpty {
                let childWidth = max(0, (width - horizontalSpacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
                let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: childWidth, height: nil)).height }.max() ?? 0
                return CGSize(width: width, height: height)
            }
            return horizontal.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache.horizontal)
        }
        return vertical.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache.vertical)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if bounds.width >= minimumHorizontalWidth {
            if equalHeight, !subviews.isEmpty {
                let width = max(0, (bounds.width - horizontalSpacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count))
                for (index, subview) in subviews.enumerated() {
                    subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + horizontalSpacing), y: bounds.minY),
                        anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
                }
            } else {
                horizontal.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache.horizontal)
            }
        } else {
            vertical.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache.vertical)
        }
    }
}
