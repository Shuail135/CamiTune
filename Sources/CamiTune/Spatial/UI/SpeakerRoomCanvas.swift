import AppKit
import SwiftUI

/// Native pointer tracking keeps the grab offset stable across SwiftUI draft updates.
struct SpeakerRoomCanvas: NSViewRepresentable {
    var topology: SpeakerTopology
    var listener: SpatialVector3
    var selected: PhysicalOutputID?
    var playing: PhysicalOutputID?
    var extent: Float
    var locked: Bool
    var listeningOnly: Bool
    var select: (PhysicalOutputID) -> Void
    var audition: (PhysicalOutputID) -> Void
    var moveSpeaker: (PhysicalOutputID, SpatialVector3) -> Void
    var moveListener: (SpatialVector3) -> Void
    var assignRole: (PhysicalOutputID, ChannelRole?) -> Void
    var zoom: CGFloat = 1.25
    var zoomChanged: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> SpeakerRoomNSView { SpeakerRoomNSView() }
    func updateNSView(_ view: SpeakerRoomNSView, context: Context) {
        view.configuration = self
        view.needsDisplay = true
        view.updateHelp()
    }
}

@MainActor
final class SpeakerRoomNSView: NSView, NSViewToolTipOwner {
    var configuration: SpeakerRoomCanvas? {
        didSet {
            guard let configuration else { return }
            if oldValue != nil {
                if oldValue?.zoom != configuration.zoom { setZoom(configuration.zoom) }
                return
            }
            zoom = configuration.zoom
            let points = configuration.topology.endpoints.compactMap(\.position).map(SpeakerLayoutGeometry.vector)
                + [configuration.listener, SpatialVector3(x: 0, y: SpeakerLayoutGeometry.screenY, z: 0)]
            initialFront = max(SpeakerLayoutGeometry.screenY, points.map(\.y).max() ?? 0)
            initialBack = min(0, points.map(\.y).min() ?? 0)
            initialHalfWidth = points.map { abs($0.x) }.max() ?? 0
        }
    }
    private var initialFront = SpeakerLayoutGeometry.screenY
    private var initialBack: Float = 0
    private var initialHalfWidth: Float = 0
    private(set) var pan = CGPoint.zero
    private(set) var zoom: CGFloat = 1.25
    private var pointerStart = CGPoint.zero
    private var panStart = CGPoint.zero
    private var worldStart = SpatialVector3(x: 0, y: 0, z: 0)
    private var target: Target?
    private var didDrag = false
    private var pressedArrow = false
    private var snapX: Float?
    private var snapY: Float?
    private var menuOutput: PhysicalOutputID?
    private var tooltipText: [NSView.ToolTipTag: String] = [:]
    private enum Target { case speaker(PhysicalOutputID), listener, pan }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var graph: CGRect { CGRect(x: 48, y: 30, width: max(1, bounds.width - 48), height: max(1, bounds.height - 30)) }
    var scale: CGFloat {
        let extent = CGFloat(configuration?.extent ?? 1)
        // Reserve room for complete speaker blocks at the default 125% zoom.
        // Snapshot extents once so dragging never causes the canvas to rescale.
        let fitWidth = max(1, graph.width / 2 - 32) / CGFloat(max(0.1, initialHalfWidth))
        let fitHeight = max(1, graph.height - 85) / CGFloat(max(0.1, initialFront - initialBack))
        let base = min(graph.width / (extent * 2), graph.height / (extent + 0.5),
                       fitWidth / 1.25, fitHeight / 1.25)
        return zoom * max(0.001, base)
    }

    var screen: CGPoint { CGPoint(x: graph.midX + pan.x, y: graph.minY + 59 + CGFloat(initialFront - SpeakerLayoutGeometry.screenY) * scale + pan.y) }
    func point(_ world: SpatialVector3) -> CGPoint {
        CGPoint(x: screen.x + CGFloat(world.x) * scale,
                y: screen.y + CGFloat(SpeakerLayoutGeometry.screenY - world.y) * scale)
    }
    func world(_ point: CGPoint) -> SpatialVector3 {
        SpatialVector3(x: Float((point.x - screen.x) / scale),
                       y: SpeakerLayoutGeometry.screenY - Float((point.y - screen.y) / scale), z: 0)
    }
    func nodePoint(_ endpoint: SpeakerEndpoint, index: Int) -> CGPoint {
        if endpoint.position != nil { return point(SpeakerLayoutGeometry.vector(endpoint.position)) }
        return CGPoint(x: graph.minX + 42 + CGFloat(index % 5) * 64 + pan.x,
                       y: graph.maxY - 28 - CGFloat(index / 5) * 44 + pan.y)
    }
    func nodeRect(_ point: CGPoint) -> CGRect { CGRect(x: point.x - 25, y: point.y - 19, width: 50, height: 38) }
    func menuRect(_ point: CGPoint) -> CGRect { CGRect(x: point.x + 8, y: point.y - 19, width: 17, height: 38) }

    func updateHelp() {
        removeAllToolTips()
        tooltipText.removeAll()
        guard let config = configuration else { return }
        for (index, endpoint) in config.topology.endpoints.enumerated() {
            let rect = nodeRect(nodePoint(endpoint, index: index)).intersection(graph)
            if !rect.isEmpty {
                let tag = addToolTip(rect, owner: self, userData: nil)
                tooltipText[tag] = "Output \(endpoint.id.channelIndex + 1): \(endpoint.displayName) · \(endpoint.role.displayName)"
            }
        }
        setAccessibilityLabel("Speaker and listening position map")
        setAccessibilityHelp("Drag speakers or the listener to move them. Drag empty space or scroll to pan. Click a speaker to test it. Use the arrow to assign its role.")
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }

    override func resetCursorRects() {
        addCursorRect(graph, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let config = configuration else { return }
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        graph.clip()
        NSColor.controlBackgroundColor.setFill(); graph.fill()
        let step = rulerStep
        let xRange = ticks(origin: screen.x, lower: graph.minX, upper: graph.maxX, step: step)
        let yRange = ticks(origin: screen.y, lower: graph.minY, upper: graph.maxY, step: step)
        let spacing = max(12, scale * 0.1)
        let grid = NSBezierPath()
        for x in stride(from: screen.x + floor((graph.minX - screen.x) / spacing) * spacing, through: graph.maxX, by: spacing) {
            for y in stride(from: screen.y + floor((graph.minY - screen.y) / spacing) * spacing, through: graph.maxY, by: spacing) {
                grid.appendOval(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill(); grid.fill()
        if let snapX { guide(from: CGPoint(x: point(SpatialVector3(x: snapX, y: 0, z: 0)).x, y: graph.minY),
                             to: CGPoint(x: point(SpatialVector3(x: snapX, y: 0, z: 0)).x, y: graph.maxY)) }
        if let snapY { guide(from: CGPoint(x: graph.minX, y: point(SpatialVector3(x: 0, y: snapY, z: 0)).y),
                             to: CGPoint(x: graph.maxX, y: point(SpatialVector3(x: 0, y: snapY, z: 0)).y)) }
        let screenBaseline = NSBezierPath()
        screenBaseline.move(to: CGPoint(x: graph.minX, y: screen.y))
        screenBaseline.line(to: CGPoint(x: graph.maxX, y: screen.y))
        NSColor.gray.setStroke(); screenBaseline.lineWidth = 1; screenBaseline.stroke()
        symbol("tv.fill", rect: CGRect(x: screen.x - 46, y: screen.y - 54, width: 92, height: 54), color: .black)
        for (index, endpoint) in config.topology.endpoints.enumerated() {
            drawSpeaker(endpoint, index: index)
        }
        let listener = point(config.listener)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: listener.x - 19, y: listener.y - 19, width: 38, height: 38)).fill()
        symbol("person.fill", rect: CGRect(x: listener.x - 11, y: listener.y - 13, width: 22, height: 26), color: .controlAccentColor)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        let frame = NSBezierPath(roundedRect: graph.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        frame.lineWidth = 1; frame.stroke()
        // Metre rulers sit outside the graph frame.
        for tick in xRange {
            let x = screen.x + tick * scale
            label(rulerLabel(tick),
                  rect: CGRect(x: x - 38, y: 5, width: 76, height: 18), alignment: .center)
        }
        for tick in yRange {
            let y = screen.y + tick * scale
            label(rulerLabel(tick),
                  rect: CGRect(x: 0, y: y - 8, width: 40, height: 18), alignment: .right)
        }
    }

    private func drawSpeaker(_ endpoint: SpeakerEndpoint, index: Int) {
            let p = nodePoint(endpoint, index: index)
            let rect = nodeRect(p)
            let selected = configuration?.selected == endpoint.id
            let disabled = endpoint.connectionState == .disabledByUser
            let background = selected
                ? (NSColor.windowBackgroundColor.blended(withFraction: 0.16, of: .controlAccentColor) ?? .windowBackgroundColor)
                : NSColor.windowBackgroundColor
            background.withAlphaComponent(1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            if selected { NSColor.controlAccentColor.setStroke(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).stroke() }
            symbol(configuration?.playing == endpoint.id ? "stop.circle.fill" : "speaker.wave.2.fill",
                   rect: CGRect(x: p.x - 20, y: p.y - 11, width: 24, height: 22),
                   color: configuration?.playing == endpoint.id ? .systemOrange : disabled ? .tertiaryLabelColor : .controlAccentColor)
            if configuration?.listeningOnly == false {
                symbol("chevron.down", rect: CGRect(x: p.x + 11, y: p.y - 4, width: 9, height: 8), color: .labelColor)
            }
    }

    private func ticks(origin: CGFloat, lower: CGFloat, upper: CGFloat, step: CGFloat) -> [CGFloat] {
        Array(stride(from: ceil((lower + 18 - origin) / (scale * step)) * step,
                     through: (upper - 18 - origin) / scale, by: step))
    }
    private func label(_ text: String, rect: CGRect, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
    private func symbol(_ name: String, rect: CGRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.withAlphaComponent(1), color.withAlphaComponent(1), color.withAlphaComponent(1)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        // Preserve the SF Symbol's native aspect ratio instead of stretching its bitmap.
        let factor = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let destination = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                 width: size.width, height: size.height)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func guide(from: CGPoint, to: CGPoint) {
        let path = NSBezierPath(); path.move(to: from); path.line(to: to)
        path.setLineDash([4, 3], count: 2, phase: 0); path.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke(); path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let config = configuration, !config.locked else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard graph.contains(p) else { return }
        window?.makeFirstResponder(self)
        pointerStart = p; panStart = pan; didDrag = false; pressedArrow = false; snapX = nil; snapY = nil
        if nodeRect(point(config.listener)).contains(p) {
            target = .listener; worldStart = config.listener; return
        }
        for (index, endpoint) in config.topology.endpoints.enumerated().reversed() {
            let center = nodePoint(endpoint, index: index)
            guard nodeRect(center).contains(p) else { continue }
            config.select(endpoint.id)
            pressedArrow = !config.listeningOnly && menuRect(center).contains(p)
            target = .speaker(endpoint.id)
            worldStart = endpoint.position == nil ? world(center) : SpeakerLayoutGeometry.vector(endpoint.position)
            return
        }
        guard graph.contains(p) else { return }
        target = .pan; NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let config = configuration, !config.locked, let target else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - pointerStart.x, dy = p.y - pointerStart.y
        guard didDrag || hypot(dx, dy) >= 3 else { return }
        didDrag = true
        if case .pan = target {
            pan = CGPoint(x: panStart.x + dx, y: panStart.y + dy); needsDisplay = true; return
        }
        if case .speaker = target, config.listeningOnly { return }
        var moved = SpeakerLayoutGeometry.dragged(worldStart, x: Float(dx), y: Float(dy), pointsPerMeter: Float(scale))
        var anchors = [SpatialVector3(x: 0, y: SpeakerLayoutGeometry.screenY, z: 0)]
        if case .speaker = target { anchors.append(config.listener) }
        for endpoint in config.topology.endpoints where endpoint.position != nil {
            if case .speaker(let id) = target, endpoint.id == id { continue }
            anchors.append(SpeakerLayoutGeometry.vector(endpoint.position))
        }
        if event.modifierFlags.contains(.option) { snapX = nil; snapY = nil }
        else {
            snapX = SpeakerLayoutGeometry.snap(moved.x, anchors: anchors.map(\.x), previous: snapX, scale: Float(scale))
            snapY = SpeakerLayoutGeometry.snap(moved.y, anchors: anchors.map(\.y), previous: snapY, scale: Float(scale))
            if let snapX { moved.x = snapX }; if let snapY { moved.y = snapY }
        }
        switch target {
        case .speaker(let id): config.moveSpeaker(id, moved)
        case .listener: config.moveListener(moved)
        case .pan: break
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let completedTarget = target
        let clicked = !didDrag
        let openMenu = pressedArrow
        if case .pan = target { NSCursor.pop() }
        target = nil; pressedArrow = false; snapX = nil; snapY = nil
        needsDisplay = true; updateHelp()
        guard clicked, case .speaker(let id) = completedTarget, let config = configuration, !config.locked else { return }
        if openMenu, let endpoint = config.topology.endpoints.first(where: { $0.id == id }) {
            showRoles(endpoint, at: convert(event.locationInWindow, from: nil))
        } else {
            config.audition(id)
        }
    }
    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard graph.contains(location) else { super.magnify(with: event); return }
        magnify(by: event.magnification, at: location)
    }
    func magnify(by amount: CGFloat, at anchor: CGPoint) {
        guard amount.isFinite, amount > -1, target == nil else { return }
        let previous = zoom
        setZoom(zoom * (1 + amount), at: anchor)
        if zoom != previous { configuration?.zoomChanged(zoom) }
    }
    override func scrollWheel(with event: NSEvent) {
        guard graph.contains(convert(event.locationInWindow, from: nil)) else { super.scrollWheel(with: event); return }
        panScroll(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                  precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase)
    }
    func panScroll(x: CGFloat, y: CGFloat, precise: Bool, momentum: NSEvent.Phase) {
        // Stop when fingers lift; swallow momentum rather than forwarding it to the parent scroll view.
        guard momentum.isEmpty, target == nil, x.isFinite, y.isFinite else { return }
        let multiplier: CGFloat = precise ? 1 : 12
        pan.x += x * multiplier; pan.y += y * multiplier
        needsDisplay = true; updateHelp()
    }
    var rulerStep: CGFloat {
        [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100].first { $0 * scale >= 44 } ?? 100
    }
    func rulerLabel(_ metres: CGFloat) -> String {
        // Use one unit consistently across both rulers at a given zoom level.
        if rulerStep < 1 { return String(format: "%g cm", abs(metres * 100)) }
        return String(format: "%g m", abs(metres))
    }
    func setZoom(_ value: CGFloat, at location: CGPoint? = nil) {
        guard value.isFinite, target == nil else { return }
        let next = min(4, max(0.25, value))
        guard next != zoom else { return }
        let anchor = location ?? CGPoint(x: graph.midX, y: graph.midY)
        let roomAnchor = world(anchor)
        zoom = next
        let shifted = point(roomAnchor)
        pan.x += anchor.x - shifted.x; pan.y += anchor.y - shifted.y
        needsDisplay = true; updateHelp()
    }
    func resetViewport() { zoom = configuration?.zoom ?? 1.25; pan = .zero; needsDisplay = true; updateHelp() }
    private func showRoles(_ endpoint: SpeakerEndpoint, at point: CGPoint) {
        roleMenu(endpoint).popUp(positioning: nil, at: point, in: self)
    }
    func roleMenu(_ endpoint: SpeakerEndpoint) -> NSMenu {
        menuOutput = endpoint.id
        let menu = NSMenu()
        let disabled = NSMenuItem(title: "Disabled", action: #selector(roleChosen(_:)), keyEquivalent: "")
        disabled.target = self; disabled.tag = -1
        disabled.state = endpoint.connectionState == .disabledByUser ? .on : .off
        menu.addItem(disabled); menu.addItem(.separator())
        for (index, role) in ChannelRole.allCases.enumerated() {
            let item = NSMenuItem(title: role == .unknown ? "Custom / Unknown" : role.displayName,
                                  action: #selector(roleChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = endpoint.connectionState != .disabledByUser && endpoint.role == role ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    @objc private func roleChosen(_ item: NSMenuItem) {
        guard let id = menuOutput else { return }
        configuration?.assignRole(id, item.tag < 0 ? nil : ChannelRole.allCases[item.tag])
    }
}
