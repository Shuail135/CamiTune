import AppKit
import SwiftUI

struct ControlLayoutItem: Identifiable {
    var id: [AnyHashable] = []
    var view: AnyView
    func prefixed(_ component: AnyHashable) -> Self {
        var copy = self
        copy.id.insert(component, at: 0)
        return copy
    }
}

/// Explicit children let the native layout owner retain each hosting view while
/// changing placement. Conditional siblings keep their own structural identity.
@resultBuilder
struct ControlLayoutItems {
    static func buildExpression<V: View>(_ view: V) -> [ControlLayoutItem] {
        [ControlLayoutItem(view: AnyView(view))]
    }
    static func buildBlock(_ groups: [ControlLayoutItem]...) -> [ControlLayoutItem] {
        groups.enumerated().flatMap { index, group in group.map { $0.prefixed(index) } }
    }
    static func buildOptional(_ group: [ControlLayoutItem]?) -> [ControlLayoutItem] { group ?? [] }
    static func buildEither(first: [ControlLayoutItem]) -> [ControlLayoutItem] { first.map { $0.prefixed(0) } }
    static func buildEither(second: [ControlLayoutItem]) -> [ControlLayoutItem] { second.map { $0.prefixed(1) } }
    static func buildArray(_ groups: [[ControlLayoutItem]]) -> [ControlLayoutItem] {
        groups.enumerated().flatMap { index, group in group.map { $0.prefixed(index) } }
    }
    static func buildExpression(_ items: [ControlLayoutItem]) -> [ControlLayoutItem] { items }
}

func controlLayoutItems<Data: RandomAccessCollection, ID: Hashable>(
    _ data: Data, id: KeyPath<Data.Element, ID>,
    @ControlLayoutItems content: (Data.Element) -> [ControlLayoutItem]
) -> [ControlLayoutItem] {
    data.flatMap { element in content(element).map { $0.prefixed(element[keyPath: id]) } }
}

typealias ControlArrangement = (size: CGSize, frames: [CGRect])
typealias ControlMeasurement = (_ index: Int, _ width: CGFloat?, _ height: CGFloat?) -> CGSize

/// Layout decisions are synchronous and event driven. Each item has one native
/// host, so resizing does not rebuild its text editor, focus, or local draft.
struct ArrangedControls: NSViewRepresentable {
    let items: [ControlLayoutItem]
    var retainedSelection: Int? = nil
    var fillsItemHeight = false
    let arrange: (_ width: CGFloat?, _ count: Int, _ measure: ControlMeasurement) -> ControlArrangement

    func makeNSView(context: Context) -> ControlLayoutSurface { ControlLayoutSurface() }
    func updateNSView(_ view: ControlLayoutSurface, context: Context) {
        view.fillsItemHeight = fillsItemHeight
        view.update(items: items, environment: context.environment, selection: retainedSelection, arrange: arrange)
    }
}

private struct ControlItemRoot: View {
    var content: AnyView
    var inherited: EnvironmentValues
    var usesIdealWidth = true
    var usesIdealHeight = true
    var contentSizeChanged: (CGSize) -> Void
    var body: some View {
        content.environment(\.self, inherited)
            .fixedSize(horizontal: usesIdealWidth, vertical: usesIdealHeight)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { contentSizeChanged(geometry.size) }
                    .onChange(of: geometry.size, perform: contentSizeChanged)
            })
    }
}

final class ControlLayoutSurface: NSView {
    private var items: [ControlLayoutItem] = []
    private var hosts: [[AnyHashable]: NSHostingController<ControlItemRoot>] = [:]
    private var arrange: ((CGFloat?, Int, ControlMeasurement) -> ControlArrangement)?
    private var selection: Int?
    var fillsItemHeight = false
    private var measuredSize = CGSize.zero
    private var measuring = false
    private var contentSizes: [[AnyHashable]: CGSize] = [:]
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { measuredSize }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // SwiftUI layout bounds are not drawing clips. Native controls, focus
        // rings and slider labels can extend beyond their alignment rectangle.
        // Page and scroll containers still own their explicit clipping.
        clipsToBounds = false
        // Report the content's actual width for alignment, while accepting a
        // narrower proposal so wrapping can reduce it on the next layout pass.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Rows report their measured content height; spare vertical space
        // belongs to adjacent scroll views, not empty space below the controls.
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [ControlLayoutItem], environment: EnvironmentValues, selection: Int?,
                arrange: @escaping (CGFloat?, Int, ControlMeasurement) -> ControlArrangement) {
        self.items = items
        self.selection = selection
        self.arrange = arrange
        let liveIDs = Set(items.map(\.id))
        for id in Array(hosts.keys) where !liveIDs.contains(id) {
            hosts.removeValue(forKey: id)?.view.removeFromSuperview()
            contentSizes.removeValue(forKey: id)
        }
        for item in items {
            if let host = hosts[item.id] {
                var root = host.rootView
                root.content = item.view
                root.inherited = environment
                host.rootView = root
            } else {
                let host = NSHostingController(rootView: ControlItemRoot(content: item.view, inherited: environment,
                    contentSizeChanged: { [weak self] size in
                        guard let self, self.contentSizes[item.id] != size else { return }
                        self.contentSizes[item.id] = size
                        if let selection = self.selection,
                           !self.items.indices.contains(selection) || self.items[selection].id != item.id { return }
                        self.needsLayout = true
                    }))
                // This owner measures and places the retained content. Avoid
                // independent automatic min/max probes in newer hosting views.
                if #available(macOS 13, *) { host.sizingOptions = [] }
                host.view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                hosts[item.id] = host
                addSubview(host.view)
            }
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.width != newSize.width
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        // AppKit coalesces invalidations and places children before displaying
        // the resized pane. A queued main-thread task can lag a resize frame.
        // updateNSView only invalidates; measuring there would reenter SwiftUI.
        performLayout()
        super.layout()
    }

    private func measure(_ index: Int, width: CGFloat?, height: CGFloat?) -> CGSize {
        guard items.indices.contains(index), let host = hosts[items[index].id] else { return .zero }
        var root = host.rootView
        if root.usesIdealWidth != (width == nil) || root.usesIdealHeight != (height == nil) {
            root.usesIdealWidth = width == nil
            root.usesIdealHeight = height == nil
            host.rootView = root
        }
        // A proposal is a constraint, not the child's measured width. Forcing
        // a frame here made fixed labels and meters fill entire equal columns.
        let fitted = host.sizeThatFits(in: CGSize(width: width ?? .infinity, height: height ?? .infinity))
        return CGSize(width: fitted.width.isFinite ? max(0, fitted.width) : 0,
                      height: fitted.height.isFinite ? max(0, fitted.height) : 0)
    }

    private func performLayout() {
        guard !measuring, let arrange else { return }
        measuring = true
        defer { measuring = false }
        let proposedWidth = bounds.width > 0 ? bounds.width : nil
        let result = arrange(proposedWidth, items.count, { self.measure($0, width: $1, height: $2) })
        for (index, item) in items.enumerated() {
            guard let host = hosts[item.id], result.frames.indices.contains(index) else { continue }
            // A hidden page's host already owns its last frame. Do not measure
            // it while placing a different page or retain a second frame cache.
            if let selection, selection != index { continue }
            let frame = result.frames[index]
            let height = fillsItemHeight ? frame.height : nil
            let fitted = measure(index, width: frame.width, height: height)
            let contentFrame = CGRect(origin: frame.origin, size: fitted)
            if host.view.frame != contentFrame { host.view.frame = contentFrame }
        }
        if result.size != measuredSize {
            measuredSize = result.size
            invalidateIntrinsicContentSize()
        }
    }
}

protocol MeasuredControlLayout {
    func arrangement(width: CGFloat?, sizes: [CGSize]) -> ControlArrangement
}

extension MeasuredControlLayout {
    func callAsFunction(@ControlLayoutItems content: () -> [ControlLayoutItem]) -> ArrangedControls {
        ArrangedControls(items: content()) { width, count, measure in
            arrangement(width: width, sizes: (0..<count).map { measure($0, nil, nil) })
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
