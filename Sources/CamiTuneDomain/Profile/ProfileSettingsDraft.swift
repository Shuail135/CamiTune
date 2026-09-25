import Foundation

package struct ProfileDeviceTypeDraft {
    package let original: DeviceProfile
    package var selectedType: ProfileEndpointKind

    package init(profile: DeviceProfile) {
        original = profile
        selectedType = profile.endpointKind
    }

    package func prepare(validate: (DeviceProfile) throws -> Void) throws -> DeviceProfile {
        var candidate = original
        if selectedType != original.endpointKind {
            candidate.playbackModesByEndpoint[original.endpointKind.rawValue] = original.playbackMode
            candidate.endpointKind = selectedType
            // Reset before asking for capabilities: availability retains legacy
            // selected modes, which must not authorize a different endpoint.
            candidate.setPlaybackMode(.direct)
            if let remembered = candidate.playbackModesByEndpoint[selectedType.rawValue],
               candidate.availablePlaybackModes.contains(remembered) {
                candidate.setPlaybackMode(remembered)
            }
        }
        try validate(candidate)
        return candidate
    }
}

/// Pure settings preflight. Applying or abandoning a draft does not persist it.
package struct ProfileSettingsDraft {
    package let original: DeviceProfile
    package let originalActivation: ProfileActivationMode
    package var name: String
    package var outputDevice: PhysicalOutputIdentity
    package var selectedType: ProfileEndpointKind
    package var sampleRate: Int
    package var activation: ProfileActivationMode
    package var sectionLayout: ProfileSectionLayout?
    package var speakerTopology: SpeakerTopology?
    package var spatialSettings: SpatialRenderSettings
    package var audioInterface: AudioInterfaceConfiguration?
    package var personalReferenceCorrections: [String: DeviceCorrectionProfile]?
    package var requestedMode: PlaybackMode?
    package var processing: ProcessingProfile?
    package var replacesUserEqualizer = false
    package var multichannel: MultichannelProcessingSettings?
    package var speakerVerification: SpeakerVerificationRecord?

    package init(profile: DeviceProfile, activation: ProfileActivationMode) {
        original = profile
        originalActivation = activation
        name = profile.name
        outputDevice = profile.outputDevice
        selectedType = profile.endpointKind
        sampleRate = profile.sampleRate
        self.activation = activation
        sectionLayout = profile.sectionLayout
        speakerTopology = profile.speakerTopology
        spatialSettings = profile.spatialSettings
        audioInterface = profile.audioInterface
    }
    package func candidate() throws -> DeviceProfile { try candidate(applyingTo: original) }

    package func candidate(applyingTo current: DeviceProfile) throws -> DeviceProfile {
        guard current.id == original.id else { throw ProfileSettingsError.staleDraft }
        // Only fields edited in this session are owned. A conflicting edit to the
        // same field is rejected; unrelated mode/EQ/volume changes survive.
        func merge<T: Equatable>(_ old: T, _ edited: T, _ fresh: T) throws -> T {
            guard edited != old else { return fresh }
            guard fresh == old || fresh == edited else { throw ProfileSettingsError.staleDraft }
            return edited
        }
        var result = current
        if outputDevice != original.outputDevice || audioInterface != original.audioInterface || selectedType != original.endpointKind { result.captureLegacyPhysicalChannels() }
        let type = try merge(original.endpointKind, selectedType, current.endpointKind)
        if type != current.endpointKind {
            var typeDraft = ProfileDeviceTypeDraft(profile: result)
            typeDraft.selectedType = type
            result = try typeDraft.prepare { _ in }
        }
        result.name = try merge(original.name, name.trimmingCharacters(in: .whitespacesAndNewlines), current.name)
        guard !result.name.isEmpty else { throw ProfileSettingsError.invalidName }
        result.outputDevice = try merge(original.outputDevice, outputDevice, current.outputDevice)
        result.sampleRate = try merge(original.sampleRate, sampleRate, current.sampleRate)
        result.sectionLayout = try merge(original.sectionLayout, sectionLayout, current.sectionLayout)
        result.speakerTopology = try merge(original.speakerTopology, speakerTopology, current.speakerTopology)
        if speakerTopology != original.speakerTopology, let topology = speakerTopology {
            try topology.validate()
            result.speakerTopologyNeedsReview = false
        }
        if sampleRate != original.sampleRate, result.speakerTopology?.deviceUID == result.outputDeviceUID {
            result.speakerTopology?.sampleRate = Double(result.sampleRate)
        }
        result.audioInterface = try merge(original.audioInterface, audioInterface, current.audioInterface)
        try result.migrateInterfaceTopology()
        if spatialSettings != original.spatialSettings {
            result.spatialSettings = try merge(original.spatialSettings, spatialSettings, current.spatialSettings)
            result.synchronizeListeningPositionCorrection()
        }
        if result.endpointKind == .audioInterface {
            guard result.audioInterface != nil else { throw ProfileSettingsError.runtime("Configure the interface channels before saving.") }
            _ = try result.validatedInterfaceConfiguration()
            _ = try result.validatedInterfaceOutputIndices()
        }
        if let requestedMode {
            _ = try merge(original.playbackMode, requestedMode, current.playbackMode)
            result.setPlaybackMode(requestedMode)
        }
        if let processing {
            result.replaceProcessing(try merge(original.processing, processing, current.processing))
        }
        if let speakerVerification {
            guard let topology = result.speakerTopology, speakerVerification.matches(topology) else { throw ProfileSettingsError.staleDraft }
            result.speakerVerification = speakerVerification
        }
        if let multichannel {
            result.multichannel = try merge(original.multichannel, multichannel, current.multichannel)
        }
        if let personalReferenceCorrections {
            result.personalReferenceCorrections = try merge(original.personalReferenceCorrections, personalReferenceCorrections, current.personalReferenceCorrections)
        }
        return result
    }

}
