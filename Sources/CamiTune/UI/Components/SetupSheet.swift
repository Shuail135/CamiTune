import SwiftUI

/// Output and Spatial setup share the same sheet chrome and native controls.
struct SetupSheet<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 38)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            content()
            Divider()
            HStack(spacing: 12) { actions() }
                .controlSize(.regular).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 780, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
