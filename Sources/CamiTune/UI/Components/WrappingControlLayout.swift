import SwiftUI

struct ControlLayoutCache { var sizes: [CGSize] }

/// Measure each child once and place its computed frame without rebuilding it.
/// Conformers own their geometry and share the native-control lifecycle.
protocol MeasuredControlLayout: Layout where Cache == ControlLayoutCache {
    func arrangement(width: CGFloat?, sizes: [CGSize]) -> (size: CGSize, frames: [CGRect])
}

extension MeasuredControlLayout {
    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(width: proposal.width, sizes: cache.sizes).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(width: bounds.width, sizes: cache.sizes)
        for (index, view) in subviews.enumerated() {
            let frame = result.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Keeps each control at its readable size and wraps whole controls into rows.
struct WrappingControlLayout: MeasuredControlLayout {
    var horizontalSpacing: CGFloat = 14
    var verticalSpacing: CGFloat = 8

    func arrangement(width proposedWidth: CGFloat?, sizes: [CGSize]) -> (size: CGSize, frames: [CGRect]) {
        let width = proposedWidth ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for size in sizes {
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
