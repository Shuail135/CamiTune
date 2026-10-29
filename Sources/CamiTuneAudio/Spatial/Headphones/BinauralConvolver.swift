import Accelerate
import Foundation

package enum BinauralConvolutionError: Error {
    case invalidConfiguration, invalidImpulseResponse, fftUnavailable
}

/// One source history feeds the two ears of the direct response and, when
/// present, the room response. Independent outputs keep Room a sample-smoothed
/// gain edit. Later partitions retain the head's fixed processing latency.
package final class BinauralConvolver {
    package let blockSize: Int
    package let sampleRate: Double
    package let expectedPeakGain: Float
    package let historyFrameCount: Int
    private let head: UniformBinauralConvolver
    private let later: [AlignedConvolutionStage]
    private let scratch = SpatialSampleBuffer(count: 256 * 5)
    package var sourceFFTCount: UInt64 { head.sourceFFTCount + later.reduce(0) { $0 + $1.kernel.sourceFFTCount } }

    package init(hrir: HRIRPair, roomResponse: HRIRPair? = nil, sampleRate: Double,
                 blockSize: Int = 128, schedulingPhase: Int = 0) throws {
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate),
              (32...512).contains(blockSize), blockSize.nonzeroBitCount == 1, schedulingPhase >= 0 else {
            throw BinauralConvolutionError.invalidConfiguration
        }
        func delayed(_ ir: [Float], seconds: Double) throws -> [Float] {
            guard !ir.isEmpty, ir.count <= 131072, ir.allSatisfy(\.isFinite),
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
        var heads: [ConvolutionResponse] = [], middle: [ConvolutionResponse] = [], tails: [ConvolutionResponse] = []
        var earGains = SIMD2<Double>(repeating: 0)
        for (component, pair) in ([hrir] + (roomResponse.map { [$0] } ?? [])).enumerated() {
            let left = try delayed(pair.left, seconds: pair.leftDelaySeconds)
            let right = try delayed(pair.right, seconds: pair.rightDelaySeconds)
            let gains = [left, right].map { $0.reduce(Double(0)) { $0 + Double(abs($1)) } }
            guard gains.allSatisfy({ $0.isFinite && $0 <= 64 }) else {
                throw BinauralConvolutionError.invalidImpulseResponse
            }
            earGains += SIMD2(gains)
            let count = max(left.count, right.count)
            // Partition each component by its own length, as before. A short
            // direct response is not repartitioned just because its room is long.
            for (ear, values) in [left, right].enumerated() {
                let output = component * 2 + ear
                if count <= 4096 {
                    heads.append(.init(output: output, samples: values))
                } else {
                    heads.append(.init(output: output, samples: Array(values.prefix(1024))))
                    if values.count > 1024 {
                        let end = count > 32768 ? min(8192, values.count) : values.count
                        middle.append(.init(output: output, samples: Array(values[1024..<end])))
                    }
                    if count > 32768, values.count > 8192 {
                        tails.append(.init(output: output, samples: Array(values[8192...])))
                    }
                }
            }
        }
        self.blockSize = blockSize
        self.sampleRate = sampleRate
        expectedPeakGain = Float(max(earGains.x, earGains.y))
        head = try UniformBinauralConvolver(responses: heads, blockSize: blockSize)
        var stages: [AlignedConvolutionStage] = []
        if !middle.isEmpty {
            stages.append(try .init(responses: middle, blockSize: 1024, offset: 1024,
                latency: blockSize, phase: schedulingPhase))
        }
        if !tails.isEmpty {
            stages.append(try .init(responses: tails, blockSize: 4096, offset: 8192,
                latency: blockSize, phase: schedulingPhase))
        }
        later = stages
        historyFrameCount = max(head.historyFrameCount, stages.map(\.historyFrameCount).max() ?? 0)
    }

    package func reset() { head.reset(); later.forEach { $0.reset() } }

    @discardableResult
    package func process(source: UnsafeBufferPointer<Float>, left: UnsafeMutableBufferPointer<Float>,
                         right: UnsafeMutableBufferPointer<Float>, roomGains: UnsafeBufferPointer<Float>? = nil) -> Bool {
        guard left.count >= source.count, right.count >= source.count,
              roomGains.map({ $0.count >= source.count }) ?? true else { return false }
        let clean = scratch.pointer, components = clean.advanced(by: 256)
        for start in stride(from: 0, to: source.count, by: 256) {
            let count = min(256, source.count - start)
            for n in 0..<count { clean[n] = SpatialSafety.sample(source[start + n]) }
            head.process(source: clean, count: count, output: components)
            for stage in later { stage.process(source: clean, count: count, accumulating: components) }
            for n in 0..<count {
                let gain = roomGains?[start + n] ?? 0
                left[start + n] = components[n * 4] + gain * components[n * 4 + 2]
                right[start + n] = components[n * 4 + 1] + gain * components[n * 4 + 3]
            }
        }
        return true
    }
}

/// Fixed storage exclusively owned by one convolution writer. Preparation owns
/// allocation; sample processing never triggers array copy-on-write work.
final class SpatialSampleBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
    }
    deinit { pointer.deinitialize(count: count); pointer.deallocate() }
    subscript(_ index: Int) -> Float {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
    func clear() { pointer.update(repeating: 0, count: count) }
}

private struct ConvolutionResponse {
    let output: Int
    let samples: [Float]
}

private final class AlignedConvolutionStage {
    let kernel: UniformBinauralConvolver
    let historyFrameCount: Int
    private let delay: SpatialSampleBuffer
    private let frames: Int
    private let scratch = SpatialSampleBuffer(count: 256 * 4)
    private var cursor = 0

    init(responses: [ConvolutionResponse], blockSize: Int, offset: Int, latency: Int, phase: Int) throws {
        kernel = try UniformBinauralConvolver(responses: responses, blockSize: blockSize, phase: phase)
        frames = offset - blockSize + latency
        delay = .init(count: frames * 4)
        historyFrameCount = offset + kernel.historyFrameCount
    }
    func reset() { kernel.reset(); cursor = 0; delay.clear() }
    func process(source: UnsafePointer<Float>, count: Int, accumulating output: UnsafeMutablePointer<Float>) {
        let next = scratch.pointer, storage = delay.pointer
        kernel.process(source: source, count: count, output: next)
        var position = cursor
        for n in 0..<count {
            let i = position * 4, destination = n * 4
            for channel in 0..<4 {
                output[destination + channel] += storage[i + channel]
                storage[i + channel] = next[destination + channel]
            }
            position += 1
            if position == frames { position = 0 }
        }
        cursor = position
    }
}

/// One filter output owns its coefficients and overlap; the source FFT history
/// and transform scratch belong to the uniform kernel shared by all outputs.
private final class ConvolutionOutput {
    let index: Int
    let activePartitions: [Int]
    let filterReal: SpatialSampleBuffer
    let filterImag: SpatialSampleBuffer
    let overlap: SpatialSampleBuffer

    init(response: ConvolutionResponse, blockSize: Int, setup: FFTSetup, logSize: vDSP_Length) {
        index = response.output
        let partitions = (response.samples.count + blockSize - 1) / blockSize
        activePartitions = (0..<partitions).filter { partition in
            response.samples[(partition * blockSize)..<min(response.samples.count, (partition + 1) * blockSize)].contains { $0 != 0 }
        }
        filterReal = .init(count: partitions * blockSize)
        filterImag = .init(count: partitions * blockSize)
        overlap = .init(count: blockSize)
        for p in activePartitions {
            for j in 0..<blockSize where p * blockSize + j < response.samples.count {
                let index = p * blockSize + j / 2
                if j.isMultiple(of: 2) { filterReal[index] = response.samples[p * blockSize + j] }
                else { filterImag[index] = response.samples[p * blockSize + j] }
            }
            var split = DSPSplitComplex(realp: filterReal.pointer + p * blockSize, imagp: filterImag.pointer + p * blockSize)
            vDSP_fft_zrip(setup, &split, 1, logSize, FFTDirection(kFFTDirection_Forward))
            // vDSP's real forward transform returns twice the mathematical
            // DFT. Normalize immutable filters once during preparation.
            for i in 0..<blockSize {
                filterReal[p * blockSize + i] *= 0.5
                filterImag[p * blockSize + i] *= 0.5
            }
        }
    }
    func reset() { overlap.clear() }
}

/// Uniform overlap-add: one forward FFT/history, independent inverse FFTs for
/// the retained ears/components. All storage is allocated during preparation.
private final class UniformBinauralConvolver {
    let blockSize: Int
    var historyFrameCount: Int { partitions * blockSize }
    private let size: Int
    private let partitions: Int
    private let logSize: vDSP_Length
    private let fft: FFTSetup
    private let outputs: [ConvolutionOutput]
    private let historyReal: SpatialSampleBuffer
    private let historyImag: SpatialSampleBuffer
    private let real: SpatialSampleBuffer
    private let imag: SpatialSampleBuffer
    private let sumReal: SpatialSampleBuffer
    private let sumImag: SpatialSampleBuffer
    private let input: SpatialSampleBuffer
    private let outputSamples: SpatialSampleBuffer
    private let phase: Int
    private var cursor: Int
    private var historyCursor = 0
    private(set) var sourceFFTCount: UInt64 = 0

    init(responses: [ConvolutionResponse], blockSize: Int, phase: Int = 0) throws {
        self.blockSize = blockSize
        self.phase = phase % blockSize
        cursor = phase % blockSize
        size = blockSize * 2
        partitions = responses.map { ($0.samples.count + blockSize - 1) / blockSize }.max()!
        logSize = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else {
            throw BinauralConvolutionError.fftUnavailable
        }
        fft = setup
        let transformLog = logSize
        outputs = responses.filter { $0.samples.contains { $0 != 0 } }.map {
            ConvolutionOutput(response: $0, blockSize: blockSize, setup: setup, logSize: transformLog)
        }
        historyReal = .init(count: partitions * blockSize)
        historyImag = .init(count: partitions * blockSize)
        real = .init(count: blockSize); imag = .init(count: blockSize)
        sumReal = .init(count: blockSize); sumImag = .init(count: blockSize)
        input = .init(count: blockSize)
        outputSamples = .init(count: blockSize * 4)
    }
    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        historyReal.clear(); historyImag.clear(); input.clear(); outputSamples.clear()
        outputs.forEach { $0.reset() }
        cursor = phase; historyCursor = 0; sourceFFTCount = 0
    }

    func process(source: UnsafePointer<Float>, count: Int, output: UnsafeMutablePointer<Float>) {
        // A prepared zero response owns no inverse transform or live history.
        // This is structural sparsity, never a silence-based truncation.
        guard !outputs.isEmpty else { output.update(repeating: 0, count: count * 4); return }
        // Borrow owned buffers and the cursor for a whole input interval. The
        // transform boundary and per-sample latency are identical to scalar OLA.
        let inputStorage = input.pointer, rendered = outputSamples.pointer
        var position = cursor, consumed = 0
        while consumed < count {
            let size = min(count - consumed, blockSize - position)
            output.advanced(by: consumed * 4).update(from: rendered.advanced(by: position * 4), count: size * 4)
            inputStorage.advanced(by: position).update(from: source.advanced(by: consumed), count: size)
            consumed += size; position += size
            if position == blockSize { renderBlock(); position = 0 }
        }
        cursor = position
    }

    private func transform(_ r: SpatialSampleBuffer, _ im: SpatialSampleBuffer, inverse: Bool) {
        var split = DSPSplitComplex(realp: r.pointer, imagp: im.pointer)
        vDSP_fft_zrip(fft, &split, 1, logSize, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
    }

    private func renderBlock() {
        let input = input.pointer, real = real.pointer, imag = imag.pointer
        let historyReal = historyReal.pointer, historyImag = historyImag.pointer
        let outR = sumReal.pointer, outI = sumImag.pointer, rendered = outputSamples.pointer
        for i in 0..<blockSize {
            real[i] = i < blockSize / 2 ? input[2 * i] : 0
            imag[i] = i < blockSize / 2 ? input[2 * i + 1] : 0
        }
        transform(self.real, self.imag, inverse: false)
        sourceFFTCount &+= 1
        historyReal.advanced(by: historyCursor * blockSize).update(from: real, count: blockSize)
        historyImag.advanced(by: historyCursor * blockSize).update(from: imag, count: blockSize)
        for output in outputs {
            let filterReal = output.filterReal.pointer, filterImag = output.filterImag.pointer
            let overlap = output.overlap.pointer, channel = output.index
            outR.update(repeating: 0, count: blockSize)
            outI.update(repeating: 0, count: blockSize)
            for p in output.activePartitions {
                let h = ((historyCursor - p + partitions) % partitions) * blockSize
                let f = p * blockSize
                // Packed bin zero holds independent DC and Nyquist values.
                // Restore their real products after the aligned, power-of-two
                // vector operation; all genuine complex bins keep their order.
                let dc = outR[0] + historyReal[h] * filterReal[f]
                let nyquist = outI[0] + historyImag[h] * filterImag[f]
                var history = DSPSplitComplex(realp: historyReal + h, imagp: historyImag + h)
                var filter = DSPSplitComplex(realp: filterReal + f, imagp: filterImag + f)
                var accumulated = DSPSplitComplex(realp: outR, imagp: outI)
                var destination = accumulated
                vDSP_zvma(&history, 1, &filter, 1, &accumulated, 1, &destination, 1, vDSP_Length(blockSize))
                outR[0] = dc; outI[0] = nyquist
            }
            transform(sumReal, sumImag, inverse: true)
            // Source forward contributes 2; inverse contributes N. Filters
            // were normalized during preparation. Unpack after 1/(2N).
            let scale = Float(1) / Float(2 * size)
            for i in 0..<(blockSize / 2) {
                let even = 2 * i, odd = even + 1
                rendered[even * 4 + channel] = outR[i] * scale + overlap[even]
                rendered[odd * 4 + channel] = outI[i] * scale + overlap[odd]
                overlap[even] = outR[i + blockSize / 2] * scale
                overlap[odd] = outI[i + blockSize / 2] * scale
            }
        }
        historyCursor = (historyCursor + 1) % partitions
    }
}
