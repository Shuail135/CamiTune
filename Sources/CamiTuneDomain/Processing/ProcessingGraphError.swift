import Foundation

package enum ProcessingGraphError: LocalizedError, Equatable {
    case invalidSampleRate
    case invalidChunkSize
    case invalidChannelCount
    case unsupportedSchemaVersion(Int)
    case unsupportedCorrectionSchemaVersion(Int)
    case channelOutOfRange(Int, Int)
    case duplicateChannel(Int)
    case duplicateStage(UUID)
    case duplicateFilter(UUID)
    case nonFiniteValue(String)
    case invalidFilterFrequency(Double, Int)
    case invalidFilterQ(Double)
    case invalidFilterBandwidth(Double)
    case missingFilterGain(EQBand.Kind)
    case missingFilterShape(EQBand.Kind)
    case invalidImpulseResponseReference(String)
    case invalidImpulseResponseMetadata
    case impulseResponseSampleRateMismatch(Int, Int)
    case impulseResponseChannelOutOfRange(Int, Int)
    case impulseResponseMissing(String)
    case crossfeedMustBeGlobal
    case crossfeedRequiresStereo(Int)
    case invalidCrossfeedAmount(Double)
    case invalidCrossfeedDelay(Double)
    case invalidCrossfeedFrequency(Double, Int)
    case delayMustBePerChannel
    case invalidChannelDelay(Double)
    case invalidLimiterCeiling(Double)

    package var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "The processing sample rate must be greater than zero."
        case .invalidChunkSize:
            return "The processing chunk size must be greater than zero."
        case .invalidChannelCount:
            return "The processing graph must contain at least one channel."
        case .unsupportedSchemaVersion(let version):
            return "This processing profile uses unsupported schema version \(version)."
        case .unsupportedCorrectionSchemaVersion(let version):
            return "This device correction uses unsupported schema version \(version)."
        case .channelOutOfRange(let index, let count):
            return "Processing channel \(index) is outside the \(count)-channel audio layout."
        case .duplicateChannel(let index):
            return "Processing channel \(index) is defined more than once."
        case .duplicateStage(let id):
            return "Processing stage \(id.uuidString) is defined more than once in a chain."
        case .duplicateFilter(let id):
            return "Equalizer filter \(id.uuidString) is defined more than once in one stage."
        case .nonFiniteValue(let name):
            return "The \(name) must be a finite number."
        case .invalidFilterFrequency(let frequency, let sampleRate):
            return "Filter frequency \(frequency) Hz must be below the Nyquist frequency for \(sampleRate) Hz audio."
        case .invalidFilterQ(let q):
            return "Filter Q must be greater than zero (received \(q))."
        case .invalidFilterBandwidth(let bandwidth):
            return "Filter bandwidth must be greater than zero (received \(bandwidth))."
        case .missingFilterGain(let kind):
            return "The \(kind.rawValue) filter requires a gain value."
        case .missingFilterShape(let kind):
            return "The \(kind.rawValue) filter requires Q or bandwidth."
        case .invalidImpulseResponseReference(let fileName):
            return "The impulse-response asset reference \(fileName) is invalid."
        case .invalidImpulseResponseMetadata:
            return "The impulse-response metadata is invalid. Import the WAV again."
        case .impulseResponseSampleRateMismatch(let impulseRate, let processingRate):
            return "The impulse response is \(impulseRate) Hz, but this profile processes at \(processingRate) Hz. Import a matching WAV to avoid changing the correction response."
        case .impulseResponseChannelOutOfRange(let channel, let count):
            return "Impulse-response channel \(channel + 1) is outside the \(count)-channel WAV."
        case .impulseResponseMissing(let name):
            return "The managed impulse response “\(name)” is missing. Import the WAV again."
        case .crossfeedMustBeGlobal:
            return "Headphone crossfeed must be a global processing stage."
        case .crossfeedRequiresStereo(let channelCount):
            return "Headphone crossfeed requires stereo audio, but this graph has \(channelCount) channels."
        case .invalidCrossfeedAmount(let amount):
            return "Crossfeed amount must be between 0% and 100% (received \(amount)%)."
        case .invalidCrossfeedDelay(let delay):
            return "Crossfeed delay must be between 0 and 5 ms (received \(delay) ms)."
        case .invalidCrossfeedFrequency(let frequency, let sampleRate):
            return "Crossfeed frequency \(frequency) Hz must be positive and below the Nyquist frequency for \(sampleRate) Hz audio."
        case .delayMustBePerChannel:
            return "Delay must target a speaker or speaker group."
        case .invalidChannelDelay(let delay):
            return "Channel delay must be between 0 and 100 ms (received \(delay) ms)."
        case .invalidLimiterCeiling(let ceiling):
            return "Limiter ceiling must be a finite value at or below 0 dBFS (received \(ceiling))."
        }
    }
}
