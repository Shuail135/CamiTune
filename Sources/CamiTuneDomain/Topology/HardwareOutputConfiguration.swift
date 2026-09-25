import Foundation

/// Hardware capacity and enabled slots, with no logical L/R or speaker meaning.
package struct HardwareOutputConfiguration: Codable, Hashable, Sendable {
    package init(deviceUID: String, hardwareChannelCount: Int, enabledHardwareOutputs: Set<Int>) {
        self.deviceUID = deviceUID
        self.hardwareChannelCount = hardwareChannelCount
        self.enabledHardwareOutputs = enabledHardwareOutputs
    }

    package var deviceUID: String
    package var hardwareChannelCount: Int
    package var enabledHardwareOutputs: Set<Int>

    package func validate(deviceUID expectedUID: String) throws {
        guard deviceUID == expectedUID, !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...SpeakerTopology.maximumOutputChannels).contains(hardwareChannelCount),
              !enabledHardwareOutputs.isEmpty,
              enabledHardwareOutputs.allSatisfy({ (0..<hardwareChannelCount).contains($0) }) else {
            throw ProfileSettingsError.runtime("Choose valid outputs on the connected audio device.")
        }
    }
}

/// The physical map can be reviewed independently of its semantic role edits.
