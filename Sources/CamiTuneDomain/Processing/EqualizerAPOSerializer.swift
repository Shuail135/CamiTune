import Foundation

package struct EqualizerAPOSerializer {
    package init() {}

    /// Drafts retain octave width so later rate/frequency changes can resolve it
    /// again. Interchange files use Q because APO ignores BW for shelf filters.
    package func serializeForExport(_ parsed: ParsedEQ, sampleRate: Double) -> String {
        var resolved = parsed
        for index in resolved.bands.indices where resolved.bands[index].q == nil && resolved.bands[index].bandwidth != nil {
            resolved.bands[index].q = resolved.bands[index].resolvedQ(sampleRate: sampleRate)
            resolved.bands[index].bandwidth = nil
        }
        return serialize(resolved)
    }
    package func serialize(_ parsed: ParsedEQ) -> String {
        var lines = ["Preamp: \(format(parsed.preampDB)) dB"]
        for (index, band) in parsed.bands.enumerated() {
            let state = band.enabled ? "ON" : "OFF"
            var line = "Filter \(index + 1): \(state) \(token(band.kind))"
            line += " Fc \(format(max(1, band.frequency))) Hz"
            if band.kind.usesGain { line += " Gain \(format(band.gain ?? 0)) dB" }
            if band.q == nil, let bandwidth = band.bandwidth {
                line += " BW Oct \(format(bandwidth))"
            } else {
                line += " Q \(format(band.q ?? 0.70710678))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
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
