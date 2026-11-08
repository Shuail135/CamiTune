import AppKit
import CoreText
import SwiftUI

/// SwiftUI measures the same font and string; one native text view owns selection
/// and copying. There is no polling or alternate rendering path by OS version.
struct SelectableText: View {
    let text: String
    @Environment(\.selectableTextFont) private var inheritedFont
    @Environment(\.selectableTextColor) private var inheritedColor
    var font: NSFont?
    var color: NSColor?

    init(_ text: String, font: NSFont? = nil, color: NSColor? = nil) {
        self.text = text; self.font = font; self.color = color
    }
    var body: some View {
        let font = font ?? inheritedFont
        let color = color ?? inheritedColor
        Text(text).font(Font(font as CTFont)).hidden()
            .overlay(SelectableTextContent(text: text, font: font, color: color))
    }
}

private struct SelectableTextContent: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text { view.string = text }
        view.font = font
        view.textColor = color
    }
}

private struct SelectableTextFont: EnvironmentKey { static let defaultValue = NSFont.preferredFont(forTextStyle: .body) }
private struct SelectableTextColor: EnvironmentKey { static let defaultValue = NSColor.labelColor }
extension EnvironmentValues {
    var selectableTextFont: NSFont {
        get { self[SelectableTextFont.self] }
        set { self[SelectableTextFont.self] = newValue }
    }
    var selectableTextColor: NSColor {
        get { self[SelectableTextColor.self] }
        set { self[SelectableTextColor.self] = newValue }
    }
}
extension View {
    func selectableTextFont(_ font: NSFont) -> some View {
        self.font(Font(font as CTFont)).environment(\.selectableTextFont, font)
    }
    func selectableTextColor(_ color: NSColor) -> some View {
        foregroundColor(Color(color)).environment(\.selectableTextColor, color)
    }
}
