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
              (1...SpeakerTopology.maximumHardwareChannels).contains(hardwareChannelCount),
              !enabledHardwareOutputs.isEmpty,
              enabledHardwareOutputs.allSatisfy({ (0..<hardwareChannelCount).contains($0) }) else {
            throw ProfileSettingsError.runtime("Choose valid outputs on the connected audio device.")
        }
        guard enabledHardwareOutputs.count <= AudioFormatDescriptor.maximumProcessingChannels else {
            throw ProfileSettingsError.runtime("Select at most \(AudioFormatDescriptor.maximumProcessingChannels) outputs for one processing profile.")
        }
    }
}

extension SpeakerTopology {
    package var enabledOutputIndices: Set<Int> {
        Set(endpoints.filter { $0.connectionState != .disabledByUser }.map(\.id.channelIndex))
    }

    package func stereoOutput(for role: ChannelRole) -> Int? {
        let matches = endpoints.filter { $0.role == role && $0.connectionState != .disabledByUser }
        return matches.count == 1 ? matches[0].id.channelIndex : nil
    }

    /// A pair picker replaces that side's physical assignment. Other speaker
    /// roles, measurements and processing identities remain attached to their slots.
    package mutating func assignStereoOutput(_ channel: Int?, to role: ChannelRole) {
        precondition(role == .left || role == .right)
        for index in endpoints.indices where endpoints[index].role == role { endpoints[index].role = .unknown }
        if let channel, let index = endpoints.firstIndex(where: { $0.id.channelIndex == channel }) {
            SpeakerLayoutGeometry.setRole(role, on: &endpoints[index])
        }
        layoutTemplateID = nil
        refreshStandardGroups()
    }

    package mutating func setOutputEnabled(_ channel: Int, enabled: Bool,
                                          confirmation: SpeakerConnectionState = .confirmedByUser) {
        guard let index = endpoints.firstIndex(where: { $0.id.channelIndex == channel }),
              enabled != (endpoints[index].connectionState != .disabledByUser) else { return }
        // A new, unlabeled speaker still needs the same displayed defaults as
        // initial setup. An explicitly Custom layout retains its unknown roles.
        endpoints[index].connectionState = !enabled ? .disabledByUser
            : (layoutTemplateID == .custom ? .confirmedByUser : confirmation)
        if layoutTemplateID != .custom { layoutTemplateID = nil }
        refreshStandardGroups()
    }
}
