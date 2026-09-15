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
    var editingChanged: (Bool) -> Void = { _ in }

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
        let fitHeight = max(1, graph.height - 100) / CGFloat(max(0.1, initialFront - initialBack))
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
    // Match the compact room map without making its drag targets too small.
    // Use the same geometry for drawing, pointer tracking, and accessibility.
    private var nodeScale: CGFloat { min(1, max(0.75, bounds.height / 370)) }

    private func nodeContentRect(_ point: CGPoint, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: point.x + x * nodeScale, y: point.y + y * nodeScale,
               width: width * nodeScale, height: height * nodeScale)
    }

    func nodeRect(_ point: CGPoint) -> CGRect {
        nodeContentRect(point, x: -25, y: -26, width: 50, height: 52)
    }
    func menuRect(_ point: CGPoint) -> CGRect {
        nodeContentRect(point, x: 8, y: -26, width: 17, height: 52)
    }

    private func displayedRole(_ endpoint: SpeakerEndpoint) -> ChannelRole {
        guard let topology = configuration?.topology,
              let index = topology.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return endpoint.role }
        return SpeakerLayoutGeometry.layoutRoles(topology)[index]
    }

    private func roleDescription(_ endpoint: SpeakerEndpoint) -> String {
        let role = displayedRole(endpoint)
        return endpoint.role == .unknown && role != .unknown ? "Estimated: \(role.displayName)" : role.displayName
    }

    func updateHelp() {
        removeAllToolTips()
        tooltipText.removeAll()
        guard let config = configuration else { return }
        for (index, endpoint) in config.topology.endpoints.enumerated() {
            let rect = nodeRect(nodePoint(endpoint, index: index)).intersection(graph)
            if !rect.isEmpty {
                let tag = addToolTip(rect, owner: self, userData: nil)
                tooltipText[tag] = "Channel \(endpoint.id.channelIndex + 1): \(endpoint.displayName) · \(roleDescription(endpoint))"
            }
        }
        updateAccessibilityElements()
        setAccessibilityLabel("Speaker and listening position map")
        setAccessibilityHelp("Drag speakers or the listener to move them. Drag empty space or scroll to pan. Click a speaker to test it. Use the arrow to assign its role. With keyboard focus, use brackets to select a speaker, L for the listener, arrow keys to move, Space to test, and R for roles.")
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }

    private var accessibilityNodes: [String: NSAccessibilityElement] = [:]
    private var keyboardListenerSelected = false

    /// Reuse virtual elements so VoiceOver focus survives local draft updates.
    func updateAccessibilityElements() {
        guard let config = configuration else { setAccessibilityChildren([]); return }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var keys: Set<String> = []
        func element(_ key: String, label: String, value: String, rect: CGRect) -> NSAccessibilityElement {
            keys.insert(key)
            let node = accessibilityNodes[key] ?? NSAccessibilityElement()
            accessibilityNodes[key] = node
            node.setAccessibilityParent(self)
            node.setAccessibilityRole(.group)
            node.setAccessibilityLabel(label)
            node.setAccessibilityValue(value)
            node.setAccessibilityFrameInParentSpace(rect)
            node.setAccessibilityEnabled(!config.locked)
            node.setAccessibilityCustomActions([])
            return node
        }
        let front = element("front", label: "Front / Screen, fixed reference", value: "", rect: nodeRect(screen))
        front.setAccessibilityRole(.staticText)
        let listener = element("listener", label: "Listening Position",
            value: String(format: "%.2f meters right, %.2f meters forward", config.listener.x, config.listener.y),
            rect: nodeRect(point(config.listener)))
        listener.setAccessibilityCustomActions(movementActions(output: nil))
        var children = [front, listener]
        for (index, endpoint) in config.topology.endpoints.enumerated() {
            let position = SpeakerLayoutGeometry.vector(endpoint.position)
            let distance = SpeakerLayoutGeometry.distance(from: endpoint.position, listenerX: config.listener.x, listenerY: config.listener.y)
            let disabled = endpoint.connectionState == .disabledByUser || endpoint.connectionState == .silent
            let node = element(endpoint.id.id, label: "\(endpoint.displayName), \(disabled ? "Disabled" : roleDescription(endpoint))",
                value: String(format: "%.2f meters from listening position, %.2f meters relative to head height. %@",
                    distance, position.z, config.playing == endpoint.id ? "Test sound playing" : "Test sound stopped"),
                rect: nodeRect(nodePoint(endpoint, index: index)))
            var actions = [NSAccessibilityCustomAction(name: "Select Speaker", handler: { [weak self] in
                guard let self, let current = self.configuration, !current.locked,
                      current.topology.endpoints.contains(where: { $0.id == endpoint.id }) else { return false }
                self.keyboardListenerSelected = false
                current.select(endpoint.id)
                return true
            })]
            if !disabled {
                actions.append(NSAccessibilityCustomAction(name: config.playing == endpoint.id ? "Stop Test Sound" : "Test Speaker", handler: { [weak self] in
                    self?.testSpeaker(endpoint.id) ?? false
                }))
            }
            if !config.listeningOnly {
                actions += movementActions(output: endpoint.id)
                actions.append(NSAccessibilityCustomAction(name: "Speaker Role: \(roleDescription(endpoint))", handler: { [weak self] in
                    guard let self, let current = self.configuration, !current.locked, !current.listeningOnly,
                          let index = current.topology.endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return false }
                    self.showRoles(current.topology.endpoints[index], at: self.nodePoint(current.topology.endpoints[index], index: index))
                    return true
                }))
            }
            node.setAccessibilityCustomActions(actions)
            children.append(node)
        }
        accessibilityNodes = accessibilityNodes.filter { keys.contains($0.key) }
        setAccessibilityChildren(children)
    }

    private func movementActions(output: PhysicalOutputID?) -> [NSAccessibilityCustomAction] {
        guard configuration?.locked == false, output == nil || configuration?.listeningOnly == false else { return [] }
        let moves: [(String, Float, Float, Float)] = [
            ("Move Left", -0.05, 0, 0), ("Move Right", 0.05, 0, 0),
            ("Move Forward", 0, 0.05, 0), ("Move Back", 0, -0.05, 0)
        ] + (output == nil ? [] : [("Raise Speaker", 0, 0, 0.05), ("Lower Speaker", 0, 0, -0.05)])
        return moves.map { name, x, y, z in
            NSAccessibilityCustomAction(name: output == nil ? "Listening Position: \(name)" : name, handler: { [weak self] in
                self?.moveAccessibly(output: output, x: x, y: y, z: z) ?? false
            })
        }
    }

    @discardableResult
    func moveAccessibly(output: PhysicalOutputID?, x: Float, y: Float, z: Float = 0) -> Bool {
        guard let config = configuration, !config.locked, x.isFinite, y.isFinite, z.isFinite else { return false }
        if let output {
            guard !config.listeningOnly, let endpoint = config.topology.endpoints.first(where: { $0.id == output }) else { return false }
            var position = SpeakerLayoutGeometry.vector(endpoint.position)
            position.x += x; position.y += y; position.z = min(10, max(-10, position.z + z))
            config.select(output)
            config.moveSpeaker(output, position)
        } else {
            var position = config.listener
            position.x += x; position.y += y
            config.moveListener(position)
        }
        return true
    }

    @discardableResult
    func testSpeaker(_ id: PhysicalOutputID) -> Bool {
        guard let config = configuration, !config.locked,
              let endpoint = config.topology.endpoints.first(where: { $0.id == id }),
              endpoint.connectionState != .disabledByUser, endpoint.connectionState != .silent else { return false }
        config.select(id); config.audition(id)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let config = configuration, !config.locked,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "l" { keyboardListenerSelected = true; return }
        if key == "[" || key == "]", !config.listeningOnly, !config.topology.endpoints.isEmpty {
            let index = config.topology.endpoints.firstIndex(where: { $0.id == config.selected }) ?? 0
            let offset = key == "]" ? 1 : -1
            let next = (index + offset + config.topology.endpoints.count) % config.topology.endpoints.count
            keyboardListenerSelected = false; config.select(config.topology.endpoints[next].id); return
        }
        let output = keyboardListenerSelected || config.listeningOnly ? nil : config.selected
        switch event.keyCode {
        case 123: moveAccessibly(output: output, x: -0.05, y: 0)
        case 124: moveAccessibly(output: output, x: 0.05, y: 0)
        case 125: moveAccessibly(output: output, x: 0, y: -0.05)
        case 126: moveAccessibly(output: output, x: 0, y: 0.05)
        case 49:
            if let output { testSpeaker(output) }
        default:
            if key == "r", let output, !config.listeningOnly,
               let index = config.topology.endpoints.firstIndex(where: { $0.id == output }) {
                showRoles(config.topology.endpoints[index], at: nodePoint(config.topology.endpoints[index], index: index))
            } else { super.keyDown(with: event) }
        }
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
        symbol("tv.fill", rect: nodeContentRect(screen, x: -46, y: -54, width: 92, height: 54), color: .black)
        for (index, endpoint) in config.topology.endpoints.enumerated() {
            drawSpeaker(endpoint, index: index)
        }
        let listener = point(config.listener)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: nodeContentRect(listener, x: -19, y: -19, width: 38, height: 38)).fill()
        symbol("person.fill", rect: nodeContentRect(listener, x: -11, y: -13, width: 22, height: 26), color: .controlAccentColor)
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
            NSBezierPath(roundedRect: rect, xRadius: 7 * nodeScale, yRadius: 7 * nodeScale).fill()
            if selected { NSColor.controlAccentColor.setStroke(); NSBezierPath(roundedRect: rect, xRadius: 7 * nodeScale, yRadius: 7 * nodeScale).stroke() }
            symbol(configuration?.playing == endpoint.id ? "stop.circle.fill" : "speaker.wave.2.fill",
                   rect: nodeContentRect(p, x: -20, y: -19, width: 24, height: 22),
                   color: configuration?.playing == endpoint.id ? .systemOrange : disabled ? .tertiaryLabelColor : .controlAccentColor)
            if configuration?.listeningOnly == false {
                symbol("chevron.down", rect: nodeContentRect(p, x: 11, y: -12, width: 9, height: 8), color: .labelColor)
            }
            if let listener = configuration?.listener,
               !SpeakerPlacementWarning.warnings(for: endpoint, listener: listener).isEmpty {
                symbol("exclamationmark.triangle.fill", rect: nodeContentRect(p, x: -25, y: -30, width: 12, height: 12), color: .systemOrange)
            }
            let role = displayedRole(endpoint)
            label(disabled ? "Off" : role.shortName,
                  rect: nodeContentRect(p, x: -23, y: 7, width: 46, height: 15), alignment: .center,
                  fontSize: max(9, 10 * nodeScale))
    }

    private func ticks(origin: CGFloat, lower: CGFloat, upper: CGFloat, step: CGFloat) -> [CGFloat] {
        Array(stride(from: ceil((lower + 18 - origin) / (scale * step)) * step,
                     through: (upper - 18 - origin) / scale, by: step))
    }
    private func label(_ text: String, rect: CGRect, alignment: NSTextAlignment, fontSize: CGFloat = 10) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: fontSize),
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
            keyboardListenerSelected = true; target = .listener; worldStart = config.listener; return
        }
        for (index, endpoint) in config.topology.endpoints.enumerated().reversed() {
            let center = nodePoint(endpoint, index: index)
            guard nodeRect(center).contains(p) else { continue }
            keyboardListenerSelected = false
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
        if !didDrag {
            UIRenderPerformance.beginSpeakerDrag()
            switch target {
            case .listener: config.editingChanged(true)
            case .speaker where !config.listeningOnly: config.editingChanged(true)
            default: break
            }
        }
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
        if didDrag { UIRenderPerformance.endSpeakerDrag() }
        if didDrag {
            switch target {
            case .listener, .speaker: configuration?.editingChanged(false)
            default: break
            }
        }
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
        menu.autoenablesItems = false
        let selectedRole = displayedRole(endpoint)
        let choices = configuration.map { SpeakerRoleChoices(topology: $0.topology, selectedRole: selectedRole) }
        func item(for role: ChannelRole) -> NSMenuItem {
            let item = NSMenuItem(title: role.displayName,
                                  action: #selector(roleChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = ChannelRole.allCases.firstIndex(of: role)!
            item.state = endpoint.connectionState != .disabledByUser && selectedRole == role ? .on : .off
            return item
        }
        for role in choices?.common ?? [endpoint.role] { menu.addItem(item(for: role)) }
        menu.addItem(.separator())
        let disabled = NSMenuItem(title: "Disabled", action: #selector(roleChosen(_:)), keyEquivalent: "")
        disabled.target = self; disabled.tag = -1
        disabled.state = endpoint.connectionState == .disabledByUser ? .on : .off
        menu.addItem(disabled); menu.addItem(.separator())
        let more = NSMenuItem(title: "More Roles…", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for role in choices?.more ?? ChannelRole.allCases { submenu.addItem(item(for: role)) }
        if !submenu.items.isEmpty {
            more.submenu = submenu
            menu.addItem(more)
        }
        return menu
    }
    @objc private func roleChosen(_ item: NSMenuItem) {
        guard let id = menuOutput, let configuration, !configuration.locked, !configuration.listeningOnly,
              configuration.topology.endpoints.contains(where: { $0.id == id }),
              item.tag == -1 || ChannelRole.allCases.indices.contains(item.tag) else { return }
        configuration.assignRole(id, item.tag < 0 ? nil : ChannelRole.allCases[item.tag])
    }
}
