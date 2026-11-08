import SwiftUI

/// Repositions the same children at the breakpoint. Fixed controls retain their
/// natural width; flexible editors share the space that remains, as in HStack.
struct ResponsiveStackLayout {
    var minimumHorizontalWidth: CGFloat
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 16
    var centered = false
    var equalHeight = false

    func callAsFunction(@ControlLayoutItems content: () -> [ControlLayoutItem]) -> ArrangedControls {
        ArrangedControls(items: content(), fillsItemHeight: equalHeight) { offered, count, measure in
            guard count > 0 else { return (.zero, []) }
            // Equal-width rows already know each child's width. Measuring an
            // unconstrained host first would rebuild its layout only to discard
            // that measurement and constrain it again in the same pass.
            let naturalWidths = offered == nil || centered
                ? (0..<count).map { measure($0, nil, nil).width } : []
            let width = offered ?? naturalWidths.reduce(0, +) + horizontalSpacing * CGFloat(count - 1)
            if width < minimumHorizontalWidth {
                var y: CGFloat = 0
                let frames = (0..<count).map { index -> CGRect in
                    let size = measure(index, centered ? min(width, naturalWidths[index]) : width, nil)
                    defer { y += size.height + verticalSpacing }
                    return CGRect(x: centered ? (width - size.width) / 2 : 0, y: y, width: size.width, height: size.height)
                }
                return (CGSize(width: width, height: max(0, y - verticalSpacing)), frames)
            }
            let gaps = horizontalSpacing * CGFloat(count - 1)
            let available = max(0, width - gaps)
            let sizes: [CGSize]
            if centered {
                sizes = (0..<count).map { measure($0, naturalWidths[$0], nil) }
            } else if equalHeight {
                sizes = (0..<count).map { measure($0, available / CGFloat(count), nil) }
            } else {
                let flexibility = (0..<count).map { index in
                    max(0, measure(index, available, nil).width - measure(index, 0, nil).width)
                }
                let order = (0..<count).sorted {
                    flexibility[$0] == flexibility[$1] ? $0 < $1 : flexibility[$0] < flexibility[$1]
                }
                var remaining = available
                var measured = [CGSize](repeating: .zero, count: count)
                for (position, index) in order.enumerated() {
                    let size = measure(index, max(0, remaining) / CGFloat(count - position), nil)
                    measured[index] = size
                    remaining -= size.width
                }
                sizes = measured
            }
            let height = sizes.map(\.height).max() ?? 0
            let widths = equalHeight ? [CGFloat](repeating: available / CGFloat(count), count: count) : sizes.map(\.width)
            let occupied = widths.reduce(0, +) + gaps
            var x = centered ? max(0, (width - occupied) / 2) : 0
            let frames = (0..<count).map { index -> CGRect in
                defer { x += widths[index] + horizontalSpacing }
                return CGRect(x: x, y: 0, width: widths[index], height: equalHeight ? height : sizes[index].height)
            }
            return (CGSize(width: centered || equalHeight ? width : occupied, height: height), frames)
        }
    }
}
