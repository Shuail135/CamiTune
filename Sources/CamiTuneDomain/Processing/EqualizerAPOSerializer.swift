import Foundation

package struct EqualizerAPOSerializer {
    package init() {}
    package func serialize(_ parsed: ParsedEQ) -> String {
        var lines = ["Preamp: \(format(parsed.preampDB)) dB"]
        for (index, band) in parsed.bands.enumerated() {
            let state = band.enabled ? "ON" : "OFF"
            var line = "Filter \(index + 1): \(state) \(token(band.kind))"
            line += " Fc \(format(max(1, band.frequency))) Hz"
            if usesGain(band.kind) { line += " Gain \(format(band.gain ?? 0)) dB" }
            line += " Q \(format(max(0.05, band.q ?? 0.70710678)))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func usesGain(_ kind: EQBand.Kind) -> Bool {
        kind == .peaking || kind == .lowShelf || kind == .highShelf
    }

    private func token(_ kind: EQBand.Kind) -> String {
        switch kind {
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LPQ"
        case .highPass: return "HPQ"
        case .notch: return "NO"
        case .allPass: return "AP"
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
