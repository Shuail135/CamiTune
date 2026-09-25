import Foundation

package struct PhysicalOutputIdentity: Identifiable, Codable, Hashable, Sendable {
    package init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    package var uid: String
    package var name: String

    package var id: String { uid }
}

package struct PhysicalDeviceDefaultProfile: Identifiable, Codable, Hashable, Sendable {
    package init(physicalDevice: PhysicalOutputIdentity, profileID: UUID) {
        self.physicalDevice = physicalDevice
        self.profileID = profileID
    }

    package var physicalDevice: PhysicalOutputIdentity
    package var profileID: UUID

    package var id: String { physicalDevice.uid }
}

package enum ProfileEndpointKind: String, Codable, CaseIterable, Sendable {
    case headphones, iem, speakers, audioInterface, custom

    package var displayName: String {
        switch self {
        case .headphones: return "Headphones"
        case .iem: return "In-ear Earphone (IEM)"
        case .speakers: return "Speakers"
        case .audioInterface: return "Audio Interface"
        case .custom: return "Custom / Unspecified"
        }
    }
}

package enum ProfileActivationMode: Hashable, Sendable {
    case physicalOutput, profileAudioDevice, manual
}

package struct AudioInterfaceConfiguration: Codable, Hashable, Sendable {
    package var hardware: HardwareOutputConfiguration
    package var connectedEndpoint: ProfileEndpointKind
    /// Only used while decoding an old profile or accepting an old-style setup
    /// edit. DeviceProfile consumes this order into physical endpoint roles.
    package private(set) var legacyOutputChannels: [Int]?

    package var deviceUID: String { hardware.deviceUID }
    package var hardwareChannelCount: Int { hardware.hardwareChannelCount }

    /// Compatibility surface for existing setup controls, never the runtime's
    /// routing authority. New hardware settings are an unordered set of slots.
    package var outputChannels: [Int] {
        get { legacyOutputChannels ?? hardware.enabledHardwareOutputs.sorted() }
        set {
            legacyOutputChannels = newValue
            hardware.enabledHardwareOutputs = Set(newValue)
        }
    }

    package init(
        deviceUID: String,
        hardwareChannelCount: Int,
        outputChannels: [Int],
        connectedEndpoint: ProfileEndpointKind
    ) {
        hardware = HardwareOutputConfiguration(deviceUID: deviceUID, hardwareChannelCount: hardwareChannelCount,
            enabledHardwareOutputs: Set(outputChannels))
        self.connectedEndpoint = connectedEndpoint; legacyOutputChannels = outputChannels
    }

    package init(hardware: HardwareOutputConfiguration, connectedEndpoint: ProfileEndpointKind) {
        self.hardware = hardware; self.connectedEndpoint = connectedEndpoint; legacyOutputChannels = nil
    }

    package mutating func finishMigration() { legacyOutputChannels = nil }

    private enum CodingKeys: String, CodingKey { case hardware, connectedEndpoint, deviceUID, hardwareChannelCount, outputChannels }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        connectedEndpoint = try values.decode(ProfileEndpointKind.self, forKey: .connectedEndpoint)
        if let hardware = try values.decodeIfPresent(HardwareOutputConfiguration.self, forKey: .hardware) {
            self.hardware = hardware
            legacyOutputChannels = try values.decodeIfPresent([Int].self, forKey: .outputChannels)
        } else {
            let outputs = try values.decode([Int].self, forKey: .outputChannels)
            hardware = try HardwareOutputConfiguration(deviceUID: values.decode(String.self, forKey: .deviceUID),
                hardwareChannelCount: values.decode(Int.self, forKey: .hardwareChannelCount), enabledHardwareOutputs: Set(outputs))
            legacyOutputChannels = outputs
        }
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hardware, forKey: .hardware)
        try values.encode(connectedEndpoint, forKey: .connectedEndpoint)
        // A standalone draft may be encoded before its profile consumes migration.
        try values.encodeIfPresent(legacyOutputChannels, forKey: .outputChannels)
    }

    package func validate(deviceUID: String) throws {
        try hardware.validate(deviceUID: deviceUID)
        guard legacyOutputChannels.map({ Set($0).count == $0.count && Set($0) == hardware.enabledHardwareOutputs }) ?? true,
              (connectedEndpoint == .speakers || hardware.enabledHardwareOutputs.count == 2),
              connectedEndpoint != .audioInterface else {
            throw ProfileSettingsError.runtime("Choose distinct hardware channels and identify what is connected to them. Personal and unspecified endpoints require two channels.")
        }
    }
}

package enum PlaybackModeReadiness: Hashable, Sendable {
    case ready, unavailable(String)
    package var isReady: Bool { self == .ready }
    package var reason: String? { if case .unavailable(let reason) = self { return reason }; return nil }
}
