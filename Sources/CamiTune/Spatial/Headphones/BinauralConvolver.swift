import Accelerate
import Foundation

enum BinauralConvolutionError: Error {
    case invalidConfiguration, invalidImpulseResponse, fftUnavailable
}

/// Uniform partitioned overlap-add convolution with one source FFT shared by
/// both ears. All storage and filter FFTs are prepared during initialization.
/// process() accepts arbitrary callback lengths and adds exactly blockSize frames
/// of algorithmic latency. The caller owns output buffers; no render allocations.
final class BinauralConvolver {
    let blockSize: Int
    let sampleRate: Double
    let expectedPeakGain: Float
    var historyFrameCount: Int { partitions * blockSize }
    private let size: Int
    private let partitions: Int
    private let logSize: vDSP_Length
    private let fft: FFTSetup
    private let filtersReal: [[Float]]
    private let filtersImag: [[Float]]
    private var historyReal: [Float]
    private var historyImag: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var sumReal: [Float]
    private var sumImag: [Float]
    private var input: [Float]
    private var outputLeft: [Float]
    private var outputRight: [Float]
    private var overlapLeft: [Float]
    private var overlapRight: [Float]
    private var cursor = 0
    private var historyCursor = 0
    private(set) var sourceFFTCount: UInt64 = 0

    init(hrir: HRIRPair, sampleRate: Double, blockSize: Int = 128) throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate),
              (32...512).contains(blockSize), blockSize.nonzeroBitCount == 1 else {
            throw BinauralConvolutionError.invalidConfiguration
        }
        func delayed(_ ir: [Float], seconds: Double) throws -> [Float] {
            guard !ir.isEmpty, ir.count <= 32768, ir.allSatisfy(\.isFinite),
                  seconds.isFinite, (0...0.1).contains(seconds) else {
                throw BinauralConvolutionError.invalidImpulseResponse
            }
            let delay = seconds * sampleRate
            let whole = Int(delay), fraction = Float(delay - Double(whole))
            var result = [Float](repeating: 0, count: ir.count + whole + 1)
            for i in ir.indices {
                result[i + whole] += ir[i] * (1 - fraction)
                result[i + whole + 1] += ir[i] * fraction
            }
            return result
        }
        let left = try delayed(hrir.left, seconds: hrir.leftDelaySeconds)
        let right = try delayed(hrir.right, seconds: hrir.rightDelaySeconds)
        let gain = max(left.reduce(Double(0)) { $0 + Double(abs($1)) },
                       right.reduce(Double(0)) { $0 + Double(abs($1)) })
        guard gain.isFinite, gain <= 64 else { throw BinauralConvolutionError.invalidImpulseResponse }
        expectedPeakGain = Float(gain)
        self.blockSize = blockSize; self.sampleRate = sampleRate
        size = blockSize * 2
        partitions = (max(left.count, right.count) + blockSize - 1) / blockSize
        logSize = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else {
            throw BinauralConvolutionError.fftUnavailable
        }
        fft = setup
        let transformSize = size, transformLog = logSize
        var fr: [[Float]] = [], fi: [[Float]] = []
        for ear in [left, right] {
            var r = [Float](repeating: 0, count: partitions * size)
            var im = [Float](repeating: 0, count: partitions * size)
            for p in 0..<partitions {
                for j in 0..<blockSize where p * blockSize + j < ear.count {
                    r[p * size + j] = ear[p * blockSize + j]
                }
                r.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress! + p * transformSize, imagp: ip.baseAddress! + p * transformSize)
                        vDSP_fft_zip(setup, &split, 1, transformLog, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
            fr.append(r); fi.append(im)
        }
        filtersReal = fr; filtersImag = fi
        historyReal = .init(repeating: 0, count: partitions * size)
        historyImag = .init(repeating: 0, count: partitions * size)
        real = .init(repeating: 0, count: size); imag = .init(repeating: 0, count: size)
        sumReal = .init(repeating: 0, count: size); sumImag = .init(repeating: 0, count: size)
        input = .init(repeating: 0, count: blockSize)
        outputLeft = .init(repeating: 0, count: blockSize); outputRight = .init(repeating: 0, count: blockSize)
        overlapLeft = .init(repeating: 0, count: blockSize); overlapRight = .init(repeating: 0, count: blockSize)
    }
    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        for i in historyReal.indices { historyReal[i] = 0; historyImag[i] = 0 }
        for i in input.indices {
            input[i] = 0; outputLeft[i] = 0; outputRight[i] = 0
            overlapLeft[i] = 0; overlapRight[i] = 0
        }
        cursor = 0; historyCursor = 0; sourceFFTCount = 0
    }

    @discardableResult
    func process(source: UnsafeBufferPointer<Float>, left: UnsafeMutableBufferPointer<Float>,
                 right: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard left.count >= source.count, right.count >= source.count else { return false }
        for i in source.indices {
            // Read before writing so callers may reuse the input for one ear.
            let result = processSample(source[i])
            left[i] = result.0; right[i] = result.1
        }
        return true
    }

    func processSample(_ sample: Float) -> (Float, Float) {
        let result = (outputLeft[cursor], outputRight[cursor])
        input[cursor] = SpatialSafety.sample(sample)
        cursor += 1
        if cursor == blockSize { renderBlock(); cursor = 0 }
        return result
    }

    private func transform(_ r: inout [Float], _ im: inout [Float], inverse: Bool) {
        r.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(fft, &split, 1, logSize, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
    }
    private func renderBlock() {
        for i in 0..<size { real[i] = i < blockSize ? input[i] : 0; imag[i] = 0 }
        transform(&real, &imag, inverse: false)
        sourceFFTCount &+= 1
        for i in 0..<size {
            historyReal[historyCursor * size + i] = real[i]
            historyImag[historyCursor * size + i] = imag[i]
        }
        for ear in 0..<2 {
            for i in 0..<size { sumReal[i] = 0; sumImag[i] = 0 }
            for p in 0..<partitions {
                let h = ((historyCursor - p + partitions) % partitions) * size
                let f = p * size
                for i in 0..<size {
                    let ar = historyReal[h + i], ai = historyImag[h + i]
                    let br = filtersReal[ear][f + i], bi = filtersImag[ear][f + i]
                    sumReal[i] += ar * br - ai * bi
                    sumImag[i] += ar * bi + ai * br
                }
            }
            transform(&sumReal, &sumImag, inverse: true)
            let scale = Float(1) / Float(size)
            for i in 0..<blockSize {
                let first = sumReal[i] * scale, tail = sumReal[i + blockSize] * scale
                if ear == 0 {
                    outputLeft[i] = first + overlapLeft[i]; overlapLeft[i] = tail
                } else {
                    outputRight[i] = first + overlapRight[i]; overlapRight[i] = tail
                }
            }
        }
        historyCursor = (historyCursor + 1) % partitions
    }
}
