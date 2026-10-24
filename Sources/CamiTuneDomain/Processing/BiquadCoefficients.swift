import Foundation

/// Shared unnormalized biquad math for response plots and per-app audio.
/// Callers retain their own input validation and Q/bandwidth fallback policy.
package struct BiquadCoefficients: Sendable {
    package let b0: Double, b1: Double, b2: Double
    package let a0: Double, a1: Double, a2: Double

    package init(kind: EQBand.Kind, frequency: Double, gainDB: Double, q: Double, sampleRate fs: Double) {
        let w0 = 2 * Double.pi * frequency / fs
        let cosw = cos(w0)
        let sinw = sin(w0)
        let A = pow(10, gainDB / 40)
        let alpha = sinw / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
        switch kind {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cosw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosw; a2 = 1 - alpha / A
        case .lowPass:
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
        case .highPass:
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
        case .notch:
            b0 = 1; b1 = -2 * cosw; b2 = 1
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cosw; b2 = 1 + alpha
        case .lowShelf, .highShelf:
            let beta = 2 * sqrt(A) * alpha
            if kind == .lowShelf {
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

        self.b0 = b0; self.b1 = b1; self.b2 = b2
        self.a0 = a0; self.a1 = a1; self.a2 = a2
    }

    package static func q(fromBandwidth bandwidth: Double) -> Double {
        1 / (2 * sinh(log(2) / 2 * bandwidth))
    }
}
