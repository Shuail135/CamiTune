import CamiTuneDomain
import SwiftUI

struct SimpleEQControlsView: View {
    @Binding var settings: SimpleToneSettings
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        ValueKnobRow {
            ForEach(SimpleEQRange.allCases) { range in
                ValueKnob(title: range.title, value: binding(for: range),
                    range: SimpleToneSettings.gainRange, step: SimpleToneSettings.step, resetValue: 0,
                    formattedValue: String(format: "%+.1f dB", settings[range]),
                    onEditingChanged: onEditingChanged)
            }
        }
    }

    private func binding(for range: SimpleEQRange) -> Binding<Double> {
        Binding(
            get: { settings[range] },
            set: { settings[range] = $0 }
        )
    }
}
