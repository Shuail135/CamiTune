import SwiftUI

struct DeviceCorrectionSectionHeader: View {
    let title: String
    let hint: String

    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            if !hint.isEmpty {
                DeviceCorrectionHelpIcon(title: title, message: hint)
            }
            Spacer()
        }
    }
}

struct DeviceCorrectionHelpIcon: View {
    let title: String
    let message: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help(message)
            .accessibilityLabel("\(title) help")
            .accessibilityHint(message)
    }
}

/// Nested Auto EQ sections share the surrounding card's surface in both appearances.
struct DeviceCorrectionCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.headline)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        }
    }
}
