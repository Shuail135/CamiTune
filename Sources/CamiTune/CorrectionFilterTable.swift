import SwiftUI

struct CorrectionFilterTable: View {
    @Binding var filters: [EQBand]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Type").frame(width: 65, alignment: .leading)
                Text("Frequency (Hz)").frame(width: 115, alignment: .leading)
                Text("Gain (dB)").frame(width: 90, alignment: .leading)
                Text("Q").frame(width: 80, alignment: .leading)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach($filters) { $band in CorrectionFilterRow(band: $band) }
        }
    }
}

private struct CorrectionFilterRow: View {
    @Binding var band: EQBand
    @State private var typeText = ""
    @State private var invalidType = false
    @FocusState private var typeFocused: Bool
    private static let kinds: [String: EQBand.Kind] = ["PK": .peaking, "LS": .lowShelf, "HS": .highShelf,
        "LP": .lowPass, "HP": .highPass, "NO": .notch, "AP": .allPass]
    private var typeName: String { Self.kinds.first { $0.value == band.kind }?.key ?? "PK" }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Type", text: $typeText).frame(width: 65).focused($typeFocused)
                    .onSubmit { setType() }.help("Type PK, LS, HS, LP, HP, NO or AP, then press Return.")
                TextField("Frequency", value: $band.frequency, format: .number).frame(width: 115)
                TextField("Gain", value: Binding(get: { band.gain ?? 0 }, set: { band.gain = $0 }), format: .number)
                    .frame(width: 90).disabled(![.peaking, .lowShelf, .highShelf].contains(band.kind))
                TextField("Q", value: Binding(get: { band.q ?? 0.707 }, set: { band.q = $0; band.bandwidth = nil }), format: .number)
                    .frame(width: 80)
                Toggle("Enabled", isOn: $band.enabled).toggleStyle(.checkbox).font(.caption)
            }.textFieldStyle(.roundedBorder)
            if invalidType { Text("Use PK, LS, HS, LP, HP, NO or AP.").font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { typeText = typeName }
        .onChange(of: band.kind) { _ in typeText = typeName }
        .onChange(of: typeFocused) { focused in if !focused { setType() } }
    }
    private func setType() {
        guard let kind = Self.kinds[typeText.uppercased().trimmingCharacters(in: .whitespaces)] else {
            invalidType = true; return
        }
        invalidType = false
        EQEditorSupport.setKind(kind, for: &band)
        typeText = typeName
    }
}
