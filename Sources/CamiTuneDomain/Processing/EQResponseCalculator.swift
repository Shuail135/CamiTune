import Foundation

package struct EQResponsePoint: Identifiable, Sendable {
    package init(frequency: Double, gainDB: Double) { self.frequency = frequency; self.gainDB = gainDB }
    package let frequency: Double
    package let gainDB: Double
    package var id: Double { frequency }
}

package struct EQResponseCalculator {
    package init() {}
    package func calculate(parsed: ParsedEQ, sampleRate: Double = 48_000, count: Int = 200) -> [EQResponsePoint] {
        let minF = 20.0
        let maxF = min(20_000.0, sampleRate * 0.49)
        let frequencies = (0..<count).map { i in
            let t = Double(i) / Double(max(1, count - 1))
            return minF * pow(maxF / minF, t)
        }
        return zip(frequencies, gainsDB(at: frequencies, parsed: parsed, sampleRate: sampleRate)).map {
            EQResponsePoint(frequency: $0, gainDB: $1)
        }
    }

    package func gainDB(at frequency: Double, parsed: ParsedEQ, sampleRate: Double) -> Double {
        var db = parsed.preampDB
        for band in parsed.bands where band.enabled {
            db += responseDB(coefficients: coefficients(for: band, sampleRate: sampleRate), frequency: frequency, sampleRate: sampleRate)
        }
        return db
    }

    /// Prepare each biquad once for a display sweep, instead of once per point.
    package func gainsDB(at frequencies: [Double], parsed: ParsedEQ, sampleRate: Double) -> [Double] {
        let prepared = parsed.bands.filter(\.enabled).map { coefficients(for: $0, sampleRate: sampleRate) }
        return frequencies.map { frequency in
            prepared.reduce(parsed.preampDB) { $0 + responseDB(coefficients: $1, frequency: frequency, sampleRate: sampleRate) }
        }
    }

    private func coefficients(for band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        let q = band.q ?? band.bandwidth.map(BiquadCoefficients.q(fromBandwidth:)) ?? 0.70710678
        return BiquadCoefficients(kind: band.kind, frequency: band.frequency,
            gainDB: band.gain ?? 0, q: q, sampleRate: sampleRate)
    }

    private func responseDB(coefficients c: BiquadCoefficients, frequency f: Double, sampleRate fs: Double) -> Double {
        let (b0, b1, b2, a0, a1, a2) = (c.b0, c.b1, c.b2, c.a0, c.a1, c.a2)
        let w = 2 * Double.pi * f / fs
        let z1r = cos(-w), z1i = sin(-w)
        let z2r = cos(-2*w), z2i = sin(-2*w)
        let nr = b0 + b1*z1r + b2*z2r
        let ni = b1*z1i + b2*z2i
        let dr = a0 + a1*z1r + a2*z2r
        let di = a1*z1i + a2*z2i
        let nMag2 = nr*nr + ni*ni
        let dMag2 = dr*dr + di*di
        return 10 * log10(max(nMag2 / max(dMag2, 1e-18), 1e-18))
    }
}
