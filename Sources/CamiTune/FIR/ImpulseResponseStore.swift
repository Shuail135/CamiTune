import CamiTuneDomain
import Accelerate
import Foundation

/// Imports external impulse responses into immutable app-managed storage.
/// CamillaDSP is then free to reload them after the file importer's temporary
/// security scope has ended.
struct ImpulseResponseStore: Sendable {
    static let fileExtensions = ["wav", "wave", "w64", "rf64", "bw64"]
    static let maximumTotalSamples = 4_194_304
    static let responseSafetyMarginDB = 0.25

    let directory: URL

    init(directory: URL = CamiTunePaths.impulseResponsesDirectory) {
        self.directory = directory
    }

    func importWAV(
        at sourceURL: URL,
        expectedSampleRate: Int? = nil
    ) throws -> ImpulseResponseAsset {
        guard Self.fileExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw ImpulseResponseImportError.unsupportedFileType
        }
        let decoded = try ImpulseResponseWAV.read(at: sourceURL, maximumSamples: Self.maximumTotalSamples)
        if let expectedSampleRate, decoded.sampleRate != expectedSampleRate {
            throw ImpulseResponseImportError.sampleRateMismatch(decoded.sampleRate, expectedSampleRate)
        }
        var maximumMagnitudeDBByChannel: [Double] = []
        for (channel, samples) in decoded.channels.enumerated() {
            guard samples.allSatisfy({ $0.isFinite }) else {
                throw ImpulseResponseImportError.nonFiniteSamples(channel)
            }
            maximumMagnitudeDBByChannel.append(
                Self.maximumMagnitudeDB(samples: samples) + Self.responseSafetyMarginDB
            )
        }
        let managedData = try decoded.encoded()

        let assetID = UUID()
        let managedFileName = "\(assetID.uuidString.lowercased()).wav"
        let asset = ImpulseResponseAsset(
            id: assetID,
            fileName: managedFileName,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            sampleRate: decoded.sampleRate,
            channelCount: decoded.channels.count,
            frameCount: decoded.frameCount,
            maximumMagnitudeDBByChannel: maximumMagnitudeDBByChannel
        )

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try managedData.write(to: url(for: asset), options: .atomic)
        } catch {
            throw ImpulseResponseImportError.couldNotStore(error.localizedDescription)
        }
        return asset
    }

    func url(for asset: ImpulseResponseAsset) -> URL {
        directory.appendingPathComponent(asset.fileName, isDirectory: false)
    }

    private static func maximumMagnitudeDB(samples: [Double]) -> Double {
        let peak = samples.reduce(0.0) { max($0, abs($1)) }
        guard peak > 0 else { return -300 }
        // Scale only the analysis input to keep the FFT finite for large float
        // coefficients. The managed WAV retains the original coefficient gain.
        let normalized = samples.map { $0 / peak }
        let fftLength = nextPowerOfTwo(max(2, samples.count))
        let log2Length = vDSP_Length(Int.bitWidth - (fftLength.leadingZeroBitCount + 1))
        guard let setup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) else {
            // Allocation failure is exceptionally unlikely after the import
            // size guard. L1 is a conservative response bound and keeps audio
            // safety intact if the FFT setup still cannot be created.
            let bound = normalized.reduce(0.0) { $0 + abs($1) }
            return amplitudeToDB(bound) + amplitudeToDB(peak)
        }
        defer { vDSP_destroy_fftsetupD(setup) }

        var real = [Double](repeating: 0, count: fftLength)
        real.replaceSubrange(0..<samples.count, with: normalized)
        var imaginary = [Double](repeating: 0, count: fftLength)
        var maximum: Double = 0
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPDoubleSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zipD(
                    setup,
                    &split,
                    1,
                    log2Length,
                    FFTDirection(kFFTDirection_Forward)
                )
                var magnitudes = [Double](repeating: 0, count: fftLength / 2 + 1)
                vDSP_zvabsD(&split, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
                vDSP_maxvD(magnitudes, 1, &maximum, vDSP_Length(magnitudes.count))
            }
        }
        return amplitudeToDB(maximum) + amplitudeToDB(peak)
    }

    private static func amplitudeToDB(_ amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else { return -300 }
        return 20 * log10(amplitude)
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}

enum ImpulseResponseImportError: LocalizedError, Equatable {
    case unsupportedFileType
    case unreadableWAV(String)
    case emptyWAV
    case incompleteWAV(expected: Int, actual: Int)
    case invalidSampleRate(Double)
    case sampleRateMismatch(Int, Int)
    case tooLarge(Int)
    case couldNotAllocate
    case nonFiniteSamples(Int)
    case couldNotStore(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Choose a WAV impulse-response file."
        case .unreadableWAV(let details):
            return "The impulse response could not be read as WAV audio. \(details)"
        case .emptyWAV:
            return "The impulse-response WAV contains no audio samples."
        case .incompleteWAV(let expected, let actual):
            return "The WAV decoder returned \(actual) of \(expected) frames. The impulse response was not imported because that would truncate the filter."
        case .invalidSampleRate(let rate):
            return "The impulse-response sample rate \(rate) Hz is invalid."
        case .sampleRateMismatch(let impulseRate, let profileRate):
            return "The impulse response is \(impulseRate) Hz, but this profile processes at \(profileRate) Hz. Export or resample the impulse response at \(profileRate) Hz and import it again."
        case .tooLarge(let maximumSamples):
            return "The impulse response is too large. CamiTune accepts at most \(maximumSamples) samples across all channels."
        case .couldNotAllocate:
            return "CamiTune could not allocate a buffer for this impulse response."
        case .nonFiniteSamples(let channel):
            return "Impulse-response channel \(channel + 1) contains invalid samples."
        case .couldNotStore(let details):
            return "CamiTune could not save the impulse response into managed storage. \(details)"
        }
    }
}
