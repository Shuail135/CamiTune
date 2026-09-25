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
        return (0..<count).map { i in
            let t = Double(i) / Double(max(1, count - 1))
            let f = minF * pow(maxF / minF, t)
            return EQResponsePoint(
                frequency: f,
                gainDB: gainDB(at: f, parsed: parsed, sampleRate: sampleRate)
            )
        }
    }

    package func gainDB(at frequency: Double, parsed: ParsedEQ, sampleRate: Double) -> Double {
        var db = parsed.preampDB
        for band in parsed.bands where band.enabled {
            db += responseDB(band: band, frequency: frequency, sampleRate: sampleRate)
        }
        return db
    }

    private func responseDB(band: EQBand, frequency f: Double, sampleRate fs: Double) -> Double {
        let q = band.q ?? qFromBandwidth(band.bandwidth) ?? 0.70710678
        let w0 = 2 * Double.pi * band.frequency / fs
        let cosw = cos(w0)
        let sinw = sin(w0)
        let A = pow(10, (band.gain ?? 0) / 40)
        let alpha = sinw / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.kind {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cosw; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case .lowShelf, .highShelf:
            let sqrtA = sqrt(A)
            let shelfAlpha = sinw / (2 * q)
            let beta = 2 * sqrtA * shelfAlpha
            if band.kind == .lowShelf {
                b0 = A * ((A + 1) - (A - 1) * cosw + beta)
                b1 = 2 * A * ((A - 1) - (A + 1) * cosw)
                b2 = A * ((A + 1) - (A - 1) * cosw - beta)
                a0 = (A + 1) + (A - 1) * cosw + beta
                a1 = -2 * ((A - 1) + (A + 1) * cosw)
                a2 = (A + 1) + (A - 1) * cosw - beta
            } else {
                b0 = A * ((A + 1) + (A - 1) * cosw + beta)
                b1 = -2 * A * ((A - 1) + (A + 1) * cosw)
                b2 = A * ((A + 1) + (A - 1) * cosw - beta)
                a0 = (A + 1) - (A - 1) * cosw + beta
                a1 = 2 * ((A - 1) - (A + 1) * cosw)
                a2 = (A + 1) - (A - 1) * cosw - beta
            }
        }

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

    private func qFromBandwidth(_ bw: Double?) -> Double? {
        guard let bw else { return nil }
        return 1.0 / (2.0 * sinh(log(2.0) / 2.0 * bw))
    }
}
