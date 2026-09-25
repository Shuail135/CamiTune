import CamiTuneDomain
import Foundation

package struct SpatialRenderContext: Sendable {
    package init(output: SpatialOutputKind, content: SpatialContentKind, amount: Float, dialogueFocus: Float, channelLayout: LPCMChannelLayout, sampleRate: Double) {
        self.output = output
        self.content = content
        self.amount = amount
        self.dialogueFocus = dialogueFocus
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
    }

    package var output: SpatialOutputKind
    package var content: SpatialContentKind
    package var amount: Float
    package var dialogueFocus: Float
    package var channelLayout: LPCMChannelLayout
    package var sampleRate: Double
}

/// Prepared DSP operates sample by sample without allocating. The PCMFrame adapter
/// owns the single output allocation required by the existing router contract.
package protocol SpatialAudioRenderer: AnyObject {
    func prepare(sampleRate: Double)
    func reset()
    func process(left: Float, right: Float, amount: Float, cinema: Float) -> (Float, Float)
}

package struct SpatialRenderDiagnostics: Sendable {
    package init(renderer: SpatialOutputKind = .speakers, content: SpatialContentKind = .music, inputChannels: Int = 0, inputPeak: Float = 0, outputPeak: Float = 0, correlation: Float = 0, appliedHeadroomDB: Float = 0, expectedGainDB: Float = 0, processingTimeMicroseconds: Double = 0, invalidSamples: UInt64 = 0, algorithmicLatencyFrames: Int = 0, hrtfProfile: String? = nil) {
        self.renderer = renderer
        self.content = content
        self.inputChannels = inputChannels
        self.inputPeak = inputPeak
        self.outputPeak = outputPeak
        self.correlation = correlation
        self.appliedHeadroomDB = appliedHeadroomDB
        self.expectedGainDB = expectedGainDB
        self.processingTimeMicroseconds = processingTimeMicroseconds
        self.invalidSamples = invalidSamples
        self.algorithmicLatencyFrames = algorithmicLatencyFrames
        self.hrtfProfile = hrtfProfile
    }

    package var renderer: SpatialOutputKind = .speakers
    package var content: SpatialContentKind = .music
    package var inputChannels = 0
    package var inputPeak: Float = 0
    package var outputPeak: Float = 0
    package var correlation: Float = 0
    package var appliedHeadroomDB: Float = 0
    package var expectedGainDB: Float = 0
    package var processingTimeMicroseconds: Double = 0
    package var invalidSamples: UInt64 = 0
    package var algorithmicLatencyFrames = 0
    package var hrtfProfile: String?
}
