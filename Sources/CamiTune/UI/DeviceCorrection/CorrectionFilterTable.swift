import CamiTuneDomain
import SwiftUI

struct CorrectionFilterTable: View {
    @Binding var filters: [EQBand]
    @Binding var selectedBandID: UUID?

    init(filters: Binding<[EQBand]>, selectedBandID: Binding<UUID?> = .constant(nil)) {
        self._filters = filters
        self._selectedBandID = selectedBandID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Type").frame(width: 100, alignment: .leading)
                Text("Frequency (Hz)").frame(width: 115, alignment: .leading)
                Text("Gain (dB)").frame(width: 90, alignment: .leading)
                Text("Q").frame(width: 80, alignment: .leading)
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(filters) { snapshot in
                CorrectionFilterRow(band: binding(for: snapshot), isSelected: selectedBandID == snapshot.id,
                    onSelect: { selectedBandID = snapshot.id },
                    onDelete: {
                        if selectedBandID == snapshot.id { selectedBandID = nil }
                        filters.removeAll { $0.id == snapshot.id }
                    })
            }
        }
    }

    private func binding(for snapshot: EQBand) -> Binding<EQBand> {
        Binding(get: { filters.first { $0.id == snapshot.id } ?? snapshot }, set: { updated in
            guard let index = filters.firstIndex(where: { $0.id == snapshot.id }) else { return }
            filters[index] = updated
        })
    }
}

private struct CorrectionFilterRow: View {
    @Binding var band: EQBand
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Picker("Type", selection: Binding(get: { band.kind }, set: { EQEditorSupport.setKind($0, for: &band) })) {
                ForEach(EQBand.Kind.allCases, id: \.self) { kind in
                    Text(Self.title(kind)).tag(kind)
                }
            }.labelsHidden().frame(width: 100)
            TextField("Frequency", value: $band.frequency, format: .number.precision(.fractionLength(0))).frame(width: 115)
            TextField("Gain", value: Binding(get: { band.gain ?? 0 }, set: { band.gain = $0 }), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 90).disabled(![.peaking, .lowShelf, .highShelf].contains(band.kind))
            TextField("Q", value: Binding(get: { band.q ?? 0.707 }, set: { band.q = $0; band.bandwidth = nil }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 80)
            Toggle("Enabled", isOn: $band.enabled).toggleStyle(.checkbox).font(.caption)
            Button { band.isLocked.toggle() } label: { Image(systemName: band.isLocked ? "lock.fill" : "lock.open") }
                .buttonStyle(.borderless).help(band.isLocked ? "Unlock band" : "Lock band")
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Delete band")
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
    }

    private static func title(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "Peaking"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        case .allPass: return "All Pass"
        }
    }
}
