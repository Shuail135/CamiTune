import Foundation

/// A validated discovery snapshot; editable profile intent remains in SpeakerTopology.
struct DetectedHardwareTopology: Hashable, Sendable {
    let speakerTopology: SpeakerTopology
    let fingerprint: HardwareTopologyFingerprint

    init(speakerTopology: SpeakerTopology) throws {
        self.fingerprint = try HardwareTopologyFingerprint(topology: speakerTopology)
        self.speakerTopology = speakerTopology
    }
}

protocol AudioHardwareTopologyProvider: Sendable {
    /// Read at the requested processing rate; this method must not change hardware.
    /// Production HAL reads belong on a worker, never an audio callback or UI body.
    func topology(for deviceUID: String, sampleRate: Double) throws -> DetectedHardwareTopology
}

/// The caller resolves a device by UID first. The existing probe also verifies
/// that its HAL object still belongs to that UID before reading channel metadata.
struct CoreAudioHardwareTopologyProvider: AudioHardwareTopologyProvider {
    let device: AudioDeviceInfo

    func topology(for deviceUID: String, sampleRate: Double) throws -> DetectedHardwareTopology {
        guard device.id == deviceUID else { throw SpeakerTopologyError.invalidDeviceUID }
        guard sampleRate.isFinite, sampleRate > 0 else { throw SpeakerTopologyError.invalidSampleRate }
        let topology = try SpeakerTopologyProbe().probe(device)
        guard topology.sampleRate == sampleRate else { throw SpeakerTopologyError.invalidSampleRate }
        return try DetectedHardwareTopology(speakerTopology: topology)
    }
}
