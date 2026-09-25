import CamiTuneDomain
import Foundation

package struct PCMFrame: Sendable {
    package var performanceTrace: AudioIntervalTraceContext?
    package var writerTrace: PCMWriterTraceContext?
    package var interleaved: [Float]
    /// Optional mode buses share this frame's exact format and timeline.
    /// `interleaved` remains the combined signal for observation branches.
    package var playbackModeSamples: [PlaybackMode: [Float]] = [:]
    package let channelCount: Int
    package let sampleRate: Double
    package let channelLayout: LPCMChannelLayout

    package init(
        interleaved: [Float],
        channelCount: Int,
        sampleRate: Double,
        channelLayout: LPCMChannelLayout? = nil
    ) {
        self.interleaved = interleaved
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.channelLayout = channelLayout
            ?? LPCMChannelLayout.canonical(forChannelCount: channelCount)
            ?? LPCMChannelLayout(
                coreAudioTag: 0,
                roles: [ChannelRole](repeating: .unknown, count: max(0, channelCount))
            )
    }

    package var frameCount: Int {
        channelCount > 0 ? interleaved.count / channelCount : 0
    }

    package var sourceFormat: SpatialSourceFormat {
        SpatialSourceFormat(layout: channelLayout)
    }
}
