import SwiftUI

/// A single disclosure presentation owns expansion, trailing controls and the
/// chevron animation. Content commits its layout without animating native fields.
struct SectionDisclosure<Label: View, Content: View, Trailing: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localExpansion = false
    private let expansion: Binding<Bool>?
    private let label: Label
    private let content: Content
    private let trailing: Trailing

    private var isExpanded: Bool { expansion?.wrappedValue ?? localExpansion }

    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder label: () -> Label) where Trailing == EmptyView {
        expansion = isExpanded
        self.content = content()
        self.label = label()
        trailing = EmptyView()
    }

    init(_ title: String, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) where Label == Text, Trailing == EmptyView {
        self.init(isExpanded: isExpanded, content: content, label: { Text(title) })
    }

    private init(expansion: Binding<Bool>?, label: Label, content: Content, trailing: Trailing) {
        self.expansion = expansion
        self.label = label
        self.content = content
        self.trailing = trailing
    }

    func trailingControls<T: View>(@ViewBuilder _ controls: () -> T) -> SectionDisclosure<Label, Content, T> {
        SectionDisclosure<Label, Content, T>(expansion: expansion, label: label, content: content, trailing: controls())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if let expansion { expansion.wrappedValue.toggle() }
                    else { localExpansion.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
                            .frame(width: 10)
                        label.uiInteractionAnchor("disclosure-label")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                trailing
            }
            if isExpanded {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
                    .transaction { $0.animation = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    /// Unlike scrollDisabled, this does not disable nested horizontal editors.
    @ViewBuilder
    func scrollBounceWhenNeeded(axes: Axis.Set = .vertical) -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize, axes: axes)
        } else {
            self
        }
    }
}
