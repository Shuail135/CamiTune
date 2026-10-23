import Accelerate
import CamiTuneDomain
import Foundation

struct ImpulseResponseChannelAnalysis: Sendable {
    let peakGainDB: Double
    /// Delay to the largest absolute tap, not device or processing-buffer latency.
    /// A silent impulse has no measurable peak delay.
    let latencyMilliseconds: Double?
    let response: [EQResponsePoint]
}

struct ImpulseResponseAnalyzer {
    func analyze(_ asset: ImpulseResponseAsset, store: ImpulseResponseStore = .init()) throws -> [ImpulseResponseChannelAnalysis] {
        let decoded = try ImpulseResponseWAV.read(at: store.url(for: asset), maximumSamples: ImpulseResponseStore.maximumTotalSamples)
        guard decoded.sampleRate == asset.sampleRate, decoded.channels.count == asset.channelCount,
              decoded.frameCount == asset.frameCount else {
            throw ImpulseResponseImportError.unreadableWAV("The stored WAV no longer matches this impulse response.")
        }
        return try decoded.channels.map { samples in
            try Task.checkCancellation()
            // Zero-padding provides enough resolution for the logarithmic display,
            // including short filters. Never truncate a long impulse response.
            let spectrum = try ImpulseResponseSpectrum(samples: samples, minimumFFTLength: 16_384)
            let peakIndex = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!
            let latency = samples[peakIndex] == 0 ? nil : Double(peakIndex) * 1_000 / Double(decoded.sampleRate)
            let upperFrequency = min(20_000, Double(decoded.sampleRate) / 2)
            let lowerFrequency = min(20, upperFrequency / 2)
            let response = (0..<512).map { index in
                let frequency = lowerFrequency * pow(upperFrequency / lowerFrequency, Double(index) / 511)
                return EQResponsePoint(frequency: frequency, gainDB: spectrum.gainDB(at: frequency, sampleRate: decoded.sampleRate))
            }
            return ImpulseResponseChannelAnalysis(peakGainDB: spectrum.maximumMagnitudeDB,
                latencyMilliseconds: latency, response: response)
        }
    }
}

/// Shared FFT analysis for import headroom and the FIR response display. Scaling
/// the analysis input keeps even very large finite coefficients safe to inspect.
struct ImpulseResponseSpectrum {
    private let magnitudes: [Double]
    private let scaleDB: Double
    private let fftLength: Int

    init(samples: [Double], minimumFFTLength: Int = 2) throws {
        let peak = samples.reduce(0.0) { max($0, abs($1)) }
        scaleDB = peak > 0 ? 20 * log10(peak) : 0
        var length = 2
        while length < max(minimumFFTLength, samples.count) { length <<= 1 }
        fftLength = length
        let log2Length = vDSP_Length(Int.bitWidth - (length.leadingZeroBitCount + 1))
        guard let setup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) else {
            throw ImpulseResponseImportError.couldNotAllocate
        }
        defer { vDSP_destroy_fftsetupD(setup) }
        var real = [Double](repeating: 0, count: length)
        if peak > 0 {
            for index in samples.indices { real[index] = samples[index] / peak }
        }
        var imaginary = [Double](repeating: 0, count: length)
        var magnitudes = [Double](repeating: 0, count: length / 2 + 1)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPDoubleSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2Length, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabsD(&split, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
            }
        }
        self.magnitudes = magnitudes
    }

    var maximumMagnitudeDB: Double { decibels(magnitudes.max() ?? 0) }

    func gainDB(at frequency: Double, sampleRate: Int) -> Double {
        let bin = min(Double(magnitudes.count - 1), max(0, frequency * Double(fftLength) / Double(sampleRate)))
        let lower = Int(bin)
        let upper = min(lower + 1, magnitudes.count - 1)
        let fraction = bin - Double(lower)
        return decibels(magnitudes[lower] * (1 - fraction) + magnitudes[upper] * fraction)
    }

    private func decibels(_ magnitude: Double) -> Double {
        guard magnitude > 0 else { return -300 }
        return 20 * log10(magnitude) + scaleDB
    }
}
