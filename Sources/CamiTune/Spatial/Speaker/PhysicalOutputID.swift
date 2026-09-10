import Foundation

/// Stable within a physical device; independent of labels and UI ordering.
struct PhysicalOutputID: Codable, Hashable, Sendable, Identifiable {
    let deviceUID: String
    let channelIndex: Int

    var id: String { "\(deviceUID)#\(channelIndex)" }

    func validate() throws {
        guard !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeakerTopologyError.invalidDeviceUID
        }
        guard (0..<SpeakerTopology.maximumOutputChannels).contains(channelIndex) else {
            throw SpeakerTopologyError.invalidChannelIndex(channelIndex)
        }
    }
}
