import SwiftUI

@MainActor
struct SectionResetButton: View {
    let title: String
    let action: @MainActor () -> Void

    init(_ title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}
