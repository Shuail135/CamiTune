import Foundation

enum SpeakerTopologyError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case hardwareLayoutChanged
    case invalidDeviceUID
    case unsupportedChannelCount(Int)
    case invalidSampleRate
    case invalidChannelIndex(Int)
    case duplicateOutput(Int)
    case foreignDevice(PhysicalOutputID)
    case invalidPosition
    case invalidBandwidth(PhysicalOutputID)

    var errorDescription: String? {
        switch self {
        case .hardwareLayoutChanged: return "The device channel layout changed. Discover and check its channels again."
        case .invalidDeviceUID, .foreignDevice: return "The speaker map belongs to another output device. Discover this device's channels again."
        case .invalidSampleRate: return "The speaker map uses a different sample rate. Rediscover it at the profile's processing rate."
        case .unsupportedChannelCount(let count): return "This output has \(count) channels. CamiTune supports 1 through 32."
        case .unsupportedVersion: return "This speaker map uses an unsupported version. Discover the channels again."
        case .invalidChannelIndex, .duplicateOutput: return "The speaker map has invalid or duplicate physical channel indices."
        case .invalidPosition: return "Speaker positions must use finite angles and a positive distance when supplied."
        case .invalidBandwidth: return "The speaker's frequency limits are invalid."
        }
    }

}

/// A physical endpoint is an independently addressable output channel.
/// It is not necessarily one visible enclosure or one driver.
/// Validate after decoding or editing and before using a topology for DSP.
struct SpeakerTopology: Codable, Hashable, Sendable {
    static let maximumOutputChannels = 32
    static let currentVersion = 1

    var version: Int = currentVersion
    var deviceUID: String
    var sampleRate: Double
    var declaredChannelCount: Int
    var endpoints: [SpeakerEndpoint]
    var hardwareRoles: [ChannelRole]? = nil
    var hardwarePositions: [SpatialPosition?]? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var activeEndpoints: [SpeakerEndpoint] {
        endpoints.filter { $0.connectionState == .acousticallyDetected }
    }

    func validateHardware(_ current: SpeakerTopology) throws {
        try current.validate()
        guard current.deviceUID == deviceUID, current.declaredChannelCount == declaredChannelCount,
              hardwareRoles == nil || current.hardwareRoles == hardwareRoles,
              hardwarePositions == nil || current.hardwarePositions == hardwarePositions else {
            throw SpeakerTopologyError.hardwareLayoutChanged
        }
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw SpeakerTopologyError.unsupportedVersion(version)
        }
        guard !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeakerTopologyError.invalidDeviceUID
        }
        guard (1...Self.maximumOutputChannels).contains(declaredChannelCount) else {
            throw SpeakerTopologyError.unsupportedChannelCount(declaredChannelCount)
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerTopologyError.invalidSampleRate
        }
        if let hardwareRoles, hardwareRoles.count != declaredChannelCount { throw SpeakerTopologyError.hardwareLayoutChanged }
        if let hardwarePositions {
            guard hardwarePositions.count == declaredChannelCount else { throw SpeakerTopologyError.hardwareLayoutChanged }
            for position in hardwarePositions { try position?.validate() }
        }
        var indices = Set<Int>()
        for endpoint in endpoints {
            try endpoint.id.validate()
            guard endpoint.id.deviceUID == deviceUID else {
                throw SpeakerTopologyError.foreignDevice(endpoint.id)
            }
            let index = endpoint.id.channelIndex
            guard index < declaredChannelCount else {
                throw SpeakerTopologyError.invalidChannelIndex(index)
            }
            guard indices.insert(index).inserted else {
                throw SpeakerTopologyError.duplicateOutput(index)
            }
            try endpoint.position?.validate()
            let low = endpoint.usableLowFrequencyHz
            let high = endpoint.usableHighFrequencyHz
            let ordered = low.flatMap { low in high.map { low <= $0 } } ?? true
            guard [low, high].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }), ordered else {
                throw SpeakerTopologyError.invalidBandwidth(endpoint.id)
            }
        }
    }
}
