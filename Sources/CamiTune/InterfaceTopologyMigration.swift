import Foundation

extension DeviceProfile {
    /// Logical stereo order is resolved from physical endpoint roles. The old
    /// ordered array is only a compatibility input until migration finishes.
    var interfaceStereoOutputIndices: [Int]? {
        guard endpointKind == .audioInterface, let assignment = audioInterface else { return nil }
        if let legacy = assignment.legacyOutputChannels { return legacy }
        guard let topology = speakerTopology, topology.deviceUID == outputDeviceUID else { return [] }
        let enabled = topology.endpoints.filter {
            assignment.hardware.enabledHardwareOutputs.contains($0.id.channelIndex)
                && ($0.connectionState == .confirmedByUser || $0.connectionState == .acousticallyDetected)
        }
        return [ChannelRole.left, .right].compactMap { role in
            let matches = enabled.filter { $0.role == role }
            return matches.count == 1 ? matches[0].id.channelIndex : nil
        }
    }

    mutating func migrateInterfaceTopology() throws {
        guard endpointKind == .audioInterface, let assignment = audioInterface,
              let legacy = assignment.legacyOutputChannels else { return }
        try assignment.validate(deviceUID: outputDeviceUID)
        // Preserve a failed topology's review requirement; do not create a guessed replacement.
        guard !speakerTopologyNeedsReview else { return }
        var topology: SpeakerTopology
        if let existing = speakerTopology {
            try existing.validate()
            guard existing.deviceUID == outputDeviceUID, existing.declaredChannelCount == assignment.hardwareChannelCount else {
                throw SpeakerTopologyError.hardwareLayoutChanged
            }
            topology = existing
        } else {
            topology = SpeakerTopology(deviceUID: outputDeviceUID, sampleRate: Double(sampleRate),
                declaredChannelCount: assignment.hardwareChannelCount,
                endpoints: (0..<assignment.hardwareChannelCount).map {
                    SpeakerEndpoint(id: PhysicalOutputID(deviceUID: outputDeviceUID, channelIndex: $0), displayName: "Channel \($0 + 1)")
                })
        }
        for index in topology.endpoints.indices {
            let physical = topology.endpoints[index].id.channelIndex
            guard legacy.contains(physical) else {
                topology.endpoints[index].connectionState = .disabledByUser
                continue
            }
            if assignment.connectedEndpoint != .speakers {
                let role: ChannelRole = physical == legacy[0] ? .left : .right
                topology.endpoints[index].role = role
                topology.endpoints[index].roleOrigin = .user
                topology.endpoints[index].connectionState = .confirmedByUser
            }
        }
        topology.groups = topology.groups.filter { $0.kind == .custom }
            + SpeakerGroup.standardGroups(for: topology.endpoints)
        try topology.validate()
        captureLegacyPhysicalChannels()
        speakerTopology = topology
        audioInterface?.finishMigration()
    }

    /// Exact terminal output order. Never sort a stereo route's physical IDs or
    /// interpret an unknown map as L/R by index once its migration is complete.
    func validatedInterfaceOutputIndices() throws -> [Int]? {
        guard let assignment = try validatedInterfaceConfiguration() else { return nil }
        guard let topology = speakerTopology, !speakerTopologyNeedsReview,
              topology.deviceUID == outputDeviceUID,
              topology.declaredChannelCount == assignment.hardwareChannelCount else {
            throw SpeakerTopologyError.hardwareLayoutChanged
        }
        try topology.validate()
        if hasPhysicalSpeakerRoute {
            let outputs = configuredProcessingChannels.map { $0.physicalOutputID.channelIndex }
            guard !outputs.isEmpty else {
                throw ProfileSettingsError.runtime("Enable and identify the connected speakers before activating this profile.")
            }
            return outputs
        }
        let outputs = interfaceStereoOutputIndices ?? []
        guard outputs.count == 2, Set(outputs).count == 2,
              Set(outputs) == assignment.hardware.enabledHardwareOutputs else {
            throw ProfileSettingsError.runtime("Assign Left and Right to the selected interface outputs before activating this profile.")
        }
        return outputs
    }
}
