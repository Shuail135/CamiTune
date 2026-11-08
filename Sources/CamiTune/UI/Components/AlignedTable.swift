import SwiftUI
import AppKit

struct AlignedTableRow {
    var cells: [ControlLayoutItem]
    init(@ControlLayoutItems content: () -> [ControlLayoutItem]) { cells = content() }
    func foregroundColor(_ color: Color) -> Self {
        var copy = self
        copy.cells = cells.map { .init(id: $0.id, view: AnyView($0.view.selectableTextColor(NSColor(color)))) }
        return copy
    }
    func fontWeight(_ weight: Font.Weight) -> Self {
        var copy = self
        copy.cells = cells.map { .init(id: $0.id, view: AnyView($0.view.modifier(InheritedFontWeight(weight: weight)))) }
        return copy
    }
    func prefixed(_ id: AnyHashable) -> Self {
        var copy = self
        copy.cells = cells.map { $0.prefixed(id) }
        return copy
    }
}

struct InheritedFontWeight: ViewModifier {
    @Environment(\.font) var font
    let weight: Font.Weight
    func body(content: Content) -> some View { content.font((font ?? .body).weight(weight)) }
}

@resultBuilder
struct AlignedTableRows {
    static func buildExpression(_ row: AlignedTableRow) -> [AlignedTableRow] { [row] }
    static func buildExpression(_ rows: [AlignedTableRow]) -> [AlignedTableRow] { rows }
    static func buildBlock(_ groups: [AlignedTableRow]...) -> [AlignedTableRow] {
        groups.enumerated().flatMap { index, rows in rows.map { $0.prefixed(index) } }
    }
    static func buildOptional(_ rows: [AlignedTableRow]?) -> [AlignedTableRow] { rows ?? [] }
    static func buildEither(first: [AlignedTableRow]) -> [AlignedTableRow] { first.map { $0.prefixed(0) } }
    static func buildEither(second: [AlignedTableRow]) -> [AlignedTableRow] { second.map { $0.prefixed(1) } }
}

func alignedTableRows<Data: RandomAccessCollection, ID: Hashable>(
    _ data: Data, id: KeyPath<Data.Element, ID>,
    @AlignedTableRows content: (Data.Element) -> [AlignedTableRow]
) -> [AlignedTableRow] {
    data.flatMap { element in content(element).map { $0.prefixed(element[keyPath: id]) } }
}

/// Tables measure each column once and share its width across all rows.
struct AlignedTable: View {
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 6
    @AlignedTableRows var rows: () -> [AlignedTableRow]

    var body: some View {
        let rows = rows()
        let items = rows.flatMap(\.cells)
        ArrangedControls(items: items) { proposedWidth, count, measure in
            var sizes = (0..<count).map { measure($0, nil, nil) }
            let columns = rows.map { $0.cells.count }.max() ?? 0
            var widths = [CGFloat](repeating: 0, count: columns)
            var index = 0
            for row in rows {
                for column in row.cells.indices {
                    widths[column] = max(widths[column], sizes[index].width)
                    index += 1
                }
            }
            let spacing = CGFloat(max(0, columns - 1)) * horizontalSpacing
            if let proposedWidth, proposedWidth < widths.reduce(0, +) + spacing {
                // Reserve compact columns first, then share the remaining
                // width among the flexible columns. Remeasure their text at
                // the assigned width so multiline rows retain their height.
                var remaining = max(0, proposedWidth - spacing)
                let order = widths.indices.sorted { widths[$0] < widths[$1] }
                for (position, column) in order.enumerated() {
                    widths[column] = min(widths[column], remaining / CGFloat(columns - position))
                    remaining -= widths[column]
                }
                index = 0
                for row in rows {
                    for column in row.cells.indices {
                        sizes[index] = measure(index, widths[column], nil)
                        index += 1
                    }
                }
            }
            var heights: [CGFloat] = []
            index = 0
            for row in rows {
                heights.append(sizes[index..<(index + row.cells.count)].map(\.height).max() ?? 0)
                index += row.cells.count
            }
            var frames: [CGRect] = []
            var y: CGFloat = 0
            index = 0
            for (rowIndex, row) in rows.enumerated() {
                var x: CGFloat = 0
                for column in row.cells.indices {
                    let size = sizes[index]
                    frames.append(CGRect(x: x, y: y + (heights[rowIndex] - size.height) / 2,
                                         width: widths[column], height: size.height))
                    x += widths[column] + horizontalSpacing
                    index += 1
                }
                y += heights[rowIndex] + verticalSpacing
            }
            return (CGSize(width: widths.reduce(0, +) + spacing,
                           height: max(0, y - verticalSpacing)), frames)
        }
    }
}
