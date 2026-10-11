import CamiTuneDomain
import Foundation

/// Windowed real-cepstral minimum phase, linear phase, or mixed phase realization
/// of the same bounded magnitude design. Never inverts spatially averaged phase.
package struct RoomFIRDesigner {
    package init() {}
    package func design(bands: [EQBand], sampleRate: Double, settings: RoomCorrectionSettings) throws -> [Float] {
        try settings.validate(sampleRate: sampleRate)
        let limit = settings.latencyLimitMS ?? 20
        var length = settings.filterLength ?? 2048
        if settings.filterLength == nil && settings.phase != .minimum {
            while length > 256 && Double(length / 2) / sampleRate * 1000 > limit { length /= 2 }
        }
        if settings.filterLength == nil && settings.phase == .minimum {
            for candidate in [2048, 4096, 8192, 16384, 32768] {
                var attempt = settings; attempt.filterLength = candidate
                do { return try design(bands: bands, sampleRate: sampleRate, settings: attempt) }
                catch RoomCorrectionError.latencyLimit { continue }
            }
            throw RoomCorrectionError.latencyLimit
        }
        try Task.checkCancellation()
        let delay = settings.phase == .minimum ? 0 : length / 2
        guard Double(delay) / sampleRate * 1000 <= limit else { throw RoomCorrectionError.latencyLimit }
        // Dense synthesis avoids accepting an aliased low-bass target merely
        // because its error falls between a short IR's FFT bins.
        let fft = try AcousticFFT(minimumSize: max(32768, length * 4))
        let size = fft.size
        let calculator = EQResponseCalculator()
        var logMagnitude = [Float](repeating: 0, count: size), imaginary = logMagnitude
        for i in 0...size / 2 {
            let f = max(1, Double(i) * sampleRate / Double(size))
            // Realize the approved continuous response, including EQ skirts.
            // A second frequency taper would make FIR differ from EQ.
            let db = calculator.gainDB(at: f, parsed: .init(preampDB: 0, bands: bands), sampleRate: sampleRate)
            logMagnitude[i] = Float(db * log(10) / 20)
            if i > 0 && i < size / 2 { logMagnitude[size - i] = logMagnitude[i] }
        }
        let desiredLog = logMagnitude
        fft.transform(real: &logMagnitude, imaginary: &imaginary, inverse: true)
        for i in 1..<size / 2 { logMagnitude[i] *= 2 }
        for i in size / 2 + 1..<size { logMagnitude[i] = 0 }
        imaginary = [Float](repeating: 0, count: size)
        fft.transform(real: &logMagnitude, imaginary: &imaginary)
        var real = logMagnitude
        for i in 0..<size {
            let phase: Double
            switch settings.phase {
            case .minimum: phase = Double(imaginary[i])
            case .linear: phase = -2 * .pi * Double(i * delay) / Double(size)
            case .mixed: phase = Double(imaginary[i]) * 0.5 - 2 * .pi * Double(i * delay) / Double(size)
            }
            let magnitude = exp(Double(desiredLog[i]))
            real[i] = Float(magnitude * cos(phase)); imaginary[i] = Float(magnitude * sin(phase))
        }
        fft.transform(real: &real, imaginary: &imaginary, inverse: true)
        real = Array(real.prefix(length))
        for i in real.indices {
            let distance = settings.phase == .minimum ? Double(i) / Double(length) : abs(Double(i - delay)) / Double(length / 2)
            let window = distance < 0.75 ? 1 : 0.5 + 0.5 * cos(.pi * min(1, (distance - 0.75) / 0.25))
            real[i] *= Float(window)
        }
        guard real.allSatisfy(\.isFinite) else { throw RoomCorrectionError.unreliable }
        // Reject truncation that would materially change the approved response.
        var check = real + [Float](repeating: 0, count: size - real.count)
        var checkI = [Float](repeating: 0, count: size)
        fft.transform(real: &check, imaginary: &checkI)
        for i in 1..<size / 2 {
            let actualDB = 10 * log10(max(1e-20, Double(check[i] * check[i] + checkI[i] * checkI[i])))
            let desiredDB = Double(desiredLog[i]) * 20 / log(10)
            guard abs(actualDB - desiredDB) < 0.15 else { throw RoomCorrectionError.latencyLimit }
        }
        return real
    }
}
