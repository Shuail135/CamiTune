import CamiTuneDomain
import Accelerate
import AVFoundation
import Foundation

/// Imports external impulse responses into immutable app-managed storage.
/// CamillaDSP is then free to reload them after the file importer's temporary
/// security scope has ended.
struct ImpulseResponseStore: Sendable {
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
        guard sourceURL.pathExtension.caseInsensitiveCompare("wav") == .orderedSame else {
            throw ImpulseResponseImportError.unsupportedFileType
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 12) ?? Data()
        } catch {
            throw ImpulseResponseImportError.unreadableWAV(error.localizedDescription)
        }
        guard header.count == 12,
              header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8) else {
            throw ImpulseResponseImportError.unreadableWAV(
                "The file does not contain a standard RIFF/WAVE header."
            )
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: sourceURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw ImpulseResponseImportError.unreadableWAV(error.localizedDescription)
        }

        let format = file.processingFormat
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw ImpulseResponseImportError.unreadableWAV(
                "Only PCM or IEEE-float WAV encoding is supported."
            )
        }
        let channelCount = Int(format.channelCount)
        let frameCount = Int(file.length)
        let roundedSampleRate = Int(format.sampleRate.rounded())
        guard channelCount > 0, frameCount > 0, roundedSampleRate > 0 else {
            throw ImpulseResponseImportError.emptyWAV
        }
        guard abs(format.sampleRate - Double(roundedSampleRate)) < 0.01 else {
            throw ImpulseResponseImportError.invalidSampleRate(format.sampleRate)
        }
        if let expectedSampleRate, roundedSampleRate != expectedSampleRate {
            throw ImpulseResponseImportError.sampleRateMismatch(
                roundedSampleRate,
                expectedSampleRate
            )
        }
        let (totalSamples, overflow) = frameCount.multipliedReportingOverflow(by: channelCount)
        guard !overflow, totalSamples <= Self.maximumTotalSamples,
              frameCount <= Int(UInt32.max) else {
            throw ImpulseResponseImportError.tooLarge(Self.maximumTotalSamples)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw ImpulseResponseImportError.couldNotAllocate
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw ImpulseResponseImportError.unreadableWAV(error.localizedDescription)
        }
        let importedFrames = Int(buffer.frameLength)
        guard importedFrames == frameCount,
              importedFrames > 0,
              let channelData = buffer.floatChannelData else {
            throw ImpulseResponseImportError.emptyWAV
        }

        var maximumMagnitudeDBByChannel: [Double] = []
        maximumMagnitudeDBByChannel.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let samples = Array(UnsafeBufferPointer(
                start: channelData[channel],
                count: importedFrames
            ))
            guard samples.allSatisfy({ $0.isFinite }) else {
                throw ImpulseResponseImportError.nonFiniteSamples(channel)
            }
            maximumMagnitudeDBByChannel.append(
                Self.maximumMagnitudeDB(samples: samples) + Self.responseSafetyMarginDB
            )
        }

        let assetID = UUID()
        let managedFileName = "\(assetID.uuidString.lowercased()).wav"
        let asset = ImpulseResponseAsset(
            id: assetID,
            fileName: managedFileName,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            sampleRate: roundedSampleRate,
            channelCount: channelCount,
            frameCount: importedFrames,
            maximumMagnitudeDBByChannel: maximumMagnitudeDBByChannel
        )

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: url(for: asset))
        } catch {
            throw ImpulseResponseImportError.couldNotStore(error.localizedDescription)
        }
        return asset
    }

    func url(for asset: ImpulseResponseAsset) -> URL {
        directory.appendingPathComponent(asset.fileName, isDirectory: false)
    }

    private static func maximumMagnitudeDB(samples: [Float]) -> Double {
        let fftLength = nextPowerOfTwo(max(2, samples.count))
        let log2Length = vDSP_Length(Int.bitWidth - (fftLength.leadingZeroBitCount + 1))
        guard let setup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
            // Allocation failure is exceptionally unlikely after the import
            // size guard. L1 is a conservative response bound and keeps audio
            // safety intact if the FFT setup still cannot be created.
            let bound = samples.reduce(0.0) { $0 + Double(abs($1)) }
            return amplitudeToDB(bound)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: fftLength)
        real.replaceSubrange(0..<samples.count, with: samples)
        var imaginary = [Float](repeating: 0, count: fftLength)
        var maximum: Float = 0
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zip(
                    setup,
                    &split,
                    1,
                    log2Length,
                    FFTDirection(kFFTDirection_Forward)
                )
                var magnitudes = [Float](repeating: 0, count: fftLength / 2 + 1)
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
                vDSP_maxv(magnitudes, 1, &maximum, vDSP_Length(magnitudes.count))
            }
        }
        return amplitudeToDB(Double(maximum))
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
            return "CamiTune could not copy the impulse response into managed storage. \(details)"
        }
    }
}
