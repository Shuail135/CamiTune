import SwiftUI

/// One joined track keeps icon/text labels and blue selection consistent,
/// including when the menu window does not have normal key-window emphasis.
struct JoinedSegmentedControl<Value: Hashable>: View {
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var controlHeight: CGFloat = 24
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var symbol: (Value) -> String? = { _ in nil }
    var unavailableReason: (Value) -> String? = { _ in nil }
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    HStack(spacing: 4) {
                        if let image = symbol(option) { Image(systemName: image) }
                        Text(title(option)).lineLimit(1)
                    }
                    .font(.system(size: labelSize))
                    .frame(maxWidth: .infinity)
                    .frame(height: controlHeight)
                    .contentShape(Rectangle())
                    .foregroundStyle(isEnabled && selection == option ? Color.white : Color.primary)
                    .background(selection == option
                        ? (isEnabled ? Color.blue : Color.secondary.opacity(0.25))
                        : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                .disabled(unavailableReason(option) != nil)
                .help(unavailableReason(option) ?? "")

                if option != options.last {
                    Rectangle()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 0.5, height: 16)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.65)
        .transaction { $0.animation = nil }
    }
}
