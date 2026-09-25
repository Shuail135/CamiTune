import Foundation

package struct ImpulseResponseAsset: Codable, Hashable, Sendable {
    package var id: UUID
    package var fileName: String
    package var displayName: String
    package var sampleRate: Int
    package var channelCount: Int
    package var frameCount: Int
    /// FFT-derived maximum magnitude for each WAV channel. The importer adds a
    /// small inter-bin safety margin, and the graph uses positive values as
    /// automatic headroom just like response-raising EQ.
    package var maximumMagnitudeDBByChannel: [Double]

    package init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        maximumMagnitudeDBByChannel: [Double]
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.maximumMagnitudeDBByChannel = maximumMagnitudeDBByChannel
    }

    package func maximumMagnitudeDB(forChannel channel: Int) -> Double? {
        guard maximumMagnitudeDBByChannel.indices.contains(channel) else { return nil }
        return maximumMagnitudeDBByChannel[channel]
    }
}
