import Foundation

struct SpatialRenderContext: Sendable {
    var output: SpatialOutputKind
    var content: SpatialContentKind
    var amount: Float
    var dialogueFocus: Float
    var channelLayout: LPCMChannelLayout
    var sampleRate: Double
}

/// Prepared DSP operates sample by sample without allocating. The PCMFrame adapter
/// owns the single output allocation required by the existing router contract.
protocol SpatialAudioRenderer: AnyObject {
    func prepare(sampleRate: Double)
    func reset()
    func process(left: Float, right: Float, amount: Float, cinema: Float) -> (Float, Float)
}

struct SpatialRenderDiagnostics: Sendable {
    var renderer: SpatialOutputKind = .speakers
    var content: SpatialContentKind = .music
    var inputChannels = 0
    var inputPeak: Float = 0
    var outputPeak: Float = 0
    var correlation: Float = 0
    var appliedHeadroomDB: Float = 0
    var expectedGainDB: Float = 0
    var processingTimeMicroseconds: Double = 0
    var invalidSamples: UInt64 = 0
    var algorithmicLatencyFrames = 0
    var hrtfProfile: String?
}
