import Foundation

// Delay decomposition and first-order equations adapted from CamillaDSP 4.1.3,
// src/filters/basicfilters.rs and biquad.rs, revision
// 05e9cfcdf43c0dfe078ed3feb8af4c8bd701fd74. Copyright (C) 2026 Henrik Enquist.
// Upstream offers GPL-3.0-only OR MPL-2.0; this adaptation selects GPL-3.0-only.
// Changes: Swift resolved parameters only; no engine/configuration or runtime
// code. Upstream notices and the selected license are recorded in THIRD_PARTY.md.
// Graph validation owns the finite cutoff, rate and 0...100 ms input contract.
package enum NativeFilterParameters {
    package typealias Coefficients = (Double, Double, Double, Double, Double)

    package static func firstOrderLowpass(_ frequency: Double, rate: Double) -> Coefficients {
        let k = tan(2 * Double.pi * frequency / rate / 2)
        let scale = 1 + k
        return (k / scale, k / scale, 0, -(1 - k) / scale, 0)
    }

    package static func delay(_ milliseconds: Double, rate: Double, subsample: Bool) -> (frames: Int, allpass: Coefficients?) {
        let samples = milliseconds / 1000 * rate
        if !subsample { return (Int(floor(samples + 0.5)), nil) }
        if samples < 0.1 { return (0, nil) }
        if samples < 1.1 {
            let coefficient = (1 - samples) / (1 + samples)
            return (0, (coefficient, 1, 0, coefficient, 0))
        }
        var integer = Int(floor(samples)) - 1
        var fraction = samples - floor(samples) + 1
        if fraction < 1.1 { integer -= 1; fraction += 1 }
        let first = 2 * (2 - fraction) / (1 + fraction)
        let second = (2 - fraction) / (2 + fraction) * (1 - fraction) / (1 + fraction)
        return (integer, (second, first, 1, first, second))
    }
}
