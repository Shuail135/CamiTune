import Foundation

/// Stable within a physical device; independent of labels and UI ordering.
package struct PhysicalOutputID: Codable, Hashable, Sendable, Identifiable {
    package init(deviceUID: String, channelIndex: Int) { self.deviceUID = deviceUID; self.channelIndex = channelIndex }

    package let deviceUID: String
    package let channelIndex: Int

    package var id: String { "\(deviceUID)#\(channelIndex)" }

    package func validate() throws {
        guard !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeakerTopologyError.invalidDeviceUID
        }
        guard (0..<SpeakerTopology.maximumOutputChannels).contains(channelIndex) else {
            throw SpeakerTopologyError.invalidChannelIndex(channelIndex)
        }
    }
}
