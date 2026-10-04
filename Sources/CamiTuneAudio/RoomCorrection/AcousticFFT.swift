import CamiTuneDomain
import Accelerate
import Foundation

package final class AcousticFFT {
    package let size: Int
    private let logSize: vDSP_Length
    private let setup: FFTSetup

    package init(minimumSize: Int) throws {
        guard minimumSize > 0, minimumSize <= 1 << 22 else { throw AcousticMeasurementError.invalidSignal }
        logSize = vDSP_Length(ceil(log2(Double(minimumSize))))
        size = 1 << Int(logSize)
        guard let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else {
            throw AcousticMeasurementError.captureFailed
        }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    package func transform(real: inout [Float], imaginary: inout [Float], inverse: Bool = false) {
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, logSize, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
        if inverse {
            let scale = Float(1) / Float(size)
            for index in real.indices { real[index] *= scale; imaginary[index] *= scale }
        }
    }
}
