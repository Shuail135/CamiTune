import SwiftUI

/// Full-width, top-aligned disclosure content keeps adjacent controls anchored.
/// Native AppKit controls cannot follow SwiftUI's interpolated layout frames.
/// Commit layout together and animate only the chevron, keeping text, fields,
/// and buttons aligned throughout expansion and collapse.
struct SectionDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: configuration.isExpanded)
                        .frame(width: 10)
                    configuration.label
                        .uiInteractionAnchor("disclosure-label")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
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
