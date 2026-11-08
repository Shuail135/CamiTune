import AppKit
import SwiftUI

/// AppKit owns the field editor and its commit/focus events. Callers retain the
/// draft and decide when it becomes a domain edit (return, blur, or cancellation).
@MainActor
struct EditableTextField: NSViewRepresentable {
    enum Style { case rounded, plain }
    let title: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var style: Style = .rounded
    var font: NSFont?
    var alignment: NSTextAlignment = .left
    var onCommit: @MainActor () -> Void = {}
    var onCancel: (@MainActor () -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, text: Binding<String>, isFocused: Binding<Bool>,
         style: Style = .rounded, font: NSFont? = nil,
         alignment: NSTextAlignment = .left, onCommit: @escaping @MainActor () -> Void = {}, onCancel: (@MainActor () -> Void)? = nil) {
        self.title = title
        _text = text
        _isFocused = isFocused
        self.style = style
        self.font = font
        self.alignment = alignment
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> DraftTextField {
        let field = DraftTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.bezelStyle = .roundedBezel
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onWindowAttachment = { [weak field, weak coordinator = context.coordinator] in
            guard let field, let coordinator else { return }
            coordinator.applyFocus(to: field)
        }
        return field
    }
    func updateNSView(_ field: DraftTextField, context: Context) {
        context.coordinator.owner = self
        if field.placeholderString != title { field.placeholderString = title }
        let controlSize: NSControl.ControlSize
        switch context.environment.controlSize {
        case .mini: controlSize = .mini
        case .small: controlSize = .small
        case .large: controlSize = .large
        default: controlSize = .regular
        }
        // AppKit's cell setters invalidate layout even for identical values.
        // Draft edits should update the text, not reset every field's chrome.
        if field.controlSize != controlSize { field.controlSize = controlSize }
        let resolvedFont = font ?? .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        if field.font != resolvedFont { field.font = resolvedFont }
        if field.alignment != alignment { field.alignment = alignment }
        if field.isBezeled != (style == .rounded) { field.isBezeled = style == .rounded }
        if field.drawsBackground != (style == .rounded) { field.drawsBackground = style == .rounded }
        if field.isEnabled != isEnabled { field.isEnabled = isEnabled }
        if field.accessibilityLabel() != title { field.setAccessibilityLabel(title) }
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() {
                editor.string = text
            }
        }
        context.coordinator.applyFocus(to: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: EditableTextField
        init(_ owner: EditableTextField) { self.owner = owner }
        func applyFocus(to field: NSTextField) {
            guard let window = field.window else { return }
            let ownsEditor = field.currentEditor() != nil
            if owner.isFocused && !ownsEditor && field.isEnabled { window.makeFirstResponder(field) }
            else if !owner.isFocused && ownsEditor { window.makeFirstResponder(nil) }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if !owner.isFocused { owner.isFocused = true }
            TextEditingCompatibility.prepare((notification.object as? NSTextField)?.currentEditor())
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if owner.text != field.stringValue { owner.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            controlTextDidChange(notification)
            if owner.isFocused { owner.isFocused = false }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                owner.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let cancel = owner.onCancel {
                cancel()
                return true
            }
            return false
        }
    }
}

final class DraftTextField: NSTextField {
    var onWindowAttachment: (@MainActor () -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachment?()
    }
}

/// Rename buttons keep their plain artwork while exposing an actual AppKit
/// responder for keyboard navigation and focus restoration after a sheet closes.
@MainActor
struct FocusButton<Label: View>: View {
    var isFocused: Binding<Bool>? = nil
    let action: @MainActor () -> Void
    var appearance: FocusButtonAppearance = .plain
    var tint: NSColor = .controlAccentColor
    @ViewBuilder var label: () -> Label
    @State private var baselines: ButtonLabelBaselines?

    var body: some View {
        FocusButtonSurface(isFocused: isFocused, action: action, appearance: appearance,
            tint: tint, receiveBaselines: { baselines = $0 }, label: label)
            .alignmentGuide(.firstTextBaseline) { baselines?.first ?? $0[.firstTextBaseline] }
            .alignmentGuide(.lastTextBaseline) { baselines?.last ?? $0[.lastTextBaseline] }
    }
}

enum FocusButtonAppearance { case plain, prominent, destructive }

private struct ButtonLabelBaselines: Equatable {
    let first: CGFloat
    let last: CGFloat
}

@MainActor
private struct FocusButtonSurface<Label: View>: NSViewRepresentable {
    var isFocused: Binding<Bool>?
    let action: @MainActor () -> Void
    var appearance: FocusButtonAppearance
    var tint: NSColor
    var receiveBaselines: (ButtonLabelBaselines) -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> FocusActionButton {
        let button = FocusActionButton()
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(FocusActionButton.invoke(_:))
        // Match SwiftUI buttons: the label determines the width. A flexible
        // AppKit view would consume the space meant for adjacent spacers.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        return button
    }
    func updateNSView(_ button: FocusActionButton, context: Context) {
        button.perform = action
        button.receiveBaselines = receiveBaselines
        button.focusChanged = { focused in
            if let isFocused, isFocused.wrappedValue != focused { isFocused.wrappedValue = focused }
        }
        button.isEnabled = isEnabled
        button.isBordered = appearance != .plain
        // Names may truncate within a column; action buttons retain the width
        // needed for their label as a sidebar or neighboring text is resized.
        button.setContentCompressionResistancePriority(appearance == .plain ? .defaultLow : .defaultHigh,
            for: .horizontal)
        button.bezelStyle = .rounded
        button.bezelColor = appearance == .prominent ? tint : nil
        button.hasDestructiveAction = appearance == .destructive
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        switch context.environment.controlSize {
        case .mini: button.controlSize = .mini; horizontalPadding = 5; verticalPadding = 1
        case .small: button.controlSize = .small; horizontalPadding = 6; verticalPadding = 1
        case .large: button.controlSize = .large; horizontalPadding = 8; verticalPadding = 6
        default: button.controlSize = .regular; horizontalPadding = 8; verticalPadding = 2
        }
        button.contentInsets = appearance == .plain ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            : NSEdgeInsets(top: verticalPadding, left: horizontalPadding, bottom: verticalPadding, right: horizontalPadding)
        button.artwork.rootView = AnyView(label().environment(\.self, context.environment))
        button.invalidateIntrinsicContentSize()
        button.requestedFocus = isFocused?.wrappedValue
        button.applyFocus()
    }
}

final class FocusActionButton: NSButton {
    final class Artwork: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    let artwork = Artwork(rootView: AnyView(EmptyView()))
    var perform: (@MainActor () -> Void)?
    var focusChanged: (@MainActor (Bool) -> Void)?
    var requestedFocus: Bool?
    fileprivate var receiveBaselines: ((ButtonLabelBaselines) -> Void)?
    private var reportedBaselines: ButtonLabelBaselines?
    var contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        addSubview(artwork)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        let size = artwork.fittingSize
        let native = isBordered ? super.intrinsicContentSize : .zero
        return NSSize(width: max(native.width, size.width + contentInsets.left + contentInsets.right),
                      height: max(native.height, size.height + contentInsets.top + contentInsets.bottom))
    }
    override func layout() {
        super.layout()
        artwork.frame = NSRect(x: contentInsets.left, y: contentInsets.bottom,
            width: max(0, bounds.width - contentInsets.left - contentInsets.right),
            height: max(0, bounds.height - contentInsets.top - contentInsets.bottom))
        artwork.layoutSubtreeIfNeeded()
        // SwiftUI's representable bridge does not forward these NSHostingView
        // baselines. Export the visible label's metrics as SwiftUI alignment
        // guides, only when they change, after the current layout completes.
        let baselines = ButtonLabelBaselines(first: contentInsets.top + artwork.firstBaselineOffsetFromTop,
            last: bounds.height - contentInsets.bottom - artwork.lastBaselineOffsetFromBottom)
        if reportedBaselines != baselines {
            reportedBaselines = baselines
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reportedBaselines == baselines else { return }
                self.receiveBaselines?(baselines)
            }
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyFocus() }
    func applyFocus() {
        guard let requestedFocus else { return }
        if requestedFocus, let window, window.firstResponder !== self, isEnabled { window.makeFirstResponder(self) }
        else if !requestedFocus, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    @objc func invoke(_ sender: Any?) { perform?() }
}

struct PrimaryActionButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var destructive = false
    var tint: NSColor = .controlAccentColor
    func makeBody(configuration: Configuration) -> some View {
        FocusButton(action: configuration.trigger, appearance: destructive ? .destructive : .prominent, tint: tint) {
            configuration.label.foregroundColor(destructive ? Color.primary : (isEnabled ? .white : Color(.disabledControlTextColor)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { configuration.trigger() }
    }
}
