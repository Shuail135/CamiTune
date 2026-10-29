import CamiTuneDomain
import Foundation

package struct PerAppFilterBank {
    package init() {}

    private struct Signature: Hashable {
        var channelCount: Int
        var sampleRate: Double
        var bands: [EQBand]
        var settingsRevision: UInt64
        var tone: SimpleToneSettings
    }

    private struct State {
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
    }

    private struct Coefficients {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
    }

    private var signature: Signature?
    private var coefficients: [Coefficients] = []
    private var states: [State] = []

    /// Retain prepared coefficients/storage while retiring signal history.
    package mutating func reset() {
        for i in states.indices { states[i] = State() }
    }

    package mutating func process(
        _ samples: inout [Float],
        channelCount: Int,
        sampleRate: Double,
        bands: [EQBand],
        settingsRevision: UInt64,
        tone: SimpleToneSettings = SimpleToneSettings()
    ) {
        prepare(channelCount: channelCount, sampleRate: sampleRate, bands: bands,
                settingsRevision: settingsRevision, tone: tone)
        // Avoid a mutable Array borrow (and possible copy) for bypassed EQ.
        guard !coefficients.isEmpty else { return }
        samples.withUnsafeMutableBufferPointer { processPrepared($0) }
    }

    /// The prepared signature owns channel count and filter history. Spatial
    /// tiles use the same arithmetic and block borrowing as per-app EQ.
    package mutating func processPrepared(_ samples: UnsafeMutableBufferPointer<Float>) {
        guard !coefficients.isEmpty else { return }
        let channelCount = signature!.channelCount
        // These histories are exclusive for the entire block. Borrow once so
        // each biquad update does not repeat array ownership/exclusivity checks.
        states.withUnsafeMutableBufferPointer { stateBuffer in
            coefficients.withUnsafeBufferPointer { filters in
                for sampleIndex in samples.indices {
                    samples[sampleIndex] = Self.filter(samples[sampleIndex], channel: sampleIndex % channelCount,
                        channelCount: channelCount, filters: filters, states: stateBuffer)
                }
            }
        }
    }

    /// Prepare on the owning worker before spatial processing starts.
    package mutating func prepare(channelCount: Int, sampleRate: Double, bands: [EQBand], settingsRevision: UInt64 = 0,
                                  tone: SimpleToneSettings = SimpleToneSettings()) {
        let nextSignature = Signature(
            channelCount: channelCount,
            sampleRate: sampleRate,
            bands: bands,
            settingsRevision: settingsRevision, tone: tone
        )
        if signature != nextSignature {
            signature = nextSignature
            let activeBands = (bands + (tone.isNeutral ? [] : ((try? SimpleToneFilterFactory.filters(for: tone, sampleRate: sampleRate)) ?? []))).filter {
                $0.enabled && $0.frequency > 0 && $0.frequency < sampleRate / 2
            }
            coefficients = activeBands.compactMap {
                Self.coefficients(for: $0, sampleRate: sampleRate)
            }
            states = [State](repeating: State(), count: coefficients.count * channelCount)
        }
    }

    private static func filter(_ input: Float, channel: Int, channelCount: Int,
                               filters: UnsafeBufferPointer<Coefficients>, states: UnsafeMutableBufferPointer<State>) -> Float {
        var value = Double(input)
        for filterIndex in filters.indices {
            let stateIndex = filterIndex * channelCount + channel
            var state = states[stateIndex]
            let c = filters[filterIndex]
            let output = c.b0 * value + c.b1 * state.x1 + c.b2 * state.x2 - c.a1 * state.y1 - c.a2 * state.y2
            state.x2 = state.x1; state.x1 = value
            state.y2 = state.y1; state.y1 = output
            states[stateIndex] = state
            value = output
        }
        return Float(value.isFinite ? value : 0)
    }

    private static func coefficients(for band: EQBand, sampleRate: Double) -> Coefficients? {
        let q: Double
        if let value = band.q, value.isFinite, value > 0 {
            q = value
        } else if let bandwidth = band.bandwidth,
                  bandwidth.isFinite, bandwidth > 0 {
            q = BiquadCoefficients.q(fromBandwidth: bandwidth)
        } else {
            q = 0.70710678
        }
        let gain = band.gain ?? 0
        guard gain.isFinite else { return nil }
        let c = BiquadCoefficients(kind: band.kind, frequency: band.frequency,
            gainDB: gain, q: q, sampleRate: sampleRate)
        let a0 = c.a0
        guard a0.isFinite, a0 != 0 else { return nil }
        return Coefficients(
            b0: c.b0 / a0,
            b1: c.b1 / a0,
            b2: c.b2 / a0,
            a1: c.a1 / a0,
            a2: c.a2 / a0
        )
    }
}
