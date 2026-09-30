import SwiftUI

struct DeviceCorrectionSectionHeader: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold())
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
