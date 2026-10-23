import Foundation

/// A non-recursive snapshot. Identity, volume, activation and section layout
/// remain profile preferences; acoustic and processing settings belong here.
package struct ProfileDeviceConfiguration: Codable, Hashable, Sendable {
    var processing: ProcessingProfile
    var physicalChannels: [PhysicalOutputID: ProcessingChain]
    var topology: SpeakerTopology?
    var topologyNeedsReview: Bool
    var verification: SpeakerVerificationRecord?
    var multichannel: MultichannelProcessingSettings
    var spatialSettings: SpatialRenderSettings
    var listener: SpatialListenerProfile?
    var acoustic: SpatialAcousticProfile?
    var contentMode: SpatialContentMode
    var surroundLayout: VirtualSurroundLayout
    var audioInterface: AudioInterfaceConfiguration?
    var playbackMode: PlaybackMode
    var referenceCorrection: DeviceCorrectionProfile?

    package init(_ profile: DeviceProfile) {
        processing = profile.processing
        physicalChannels = profile.physicalChannelProcessing
        topology = profile.speakerTopology
        topologyNeedsReview = profile.speakerTopologyNeedsReview
        verification = profile.speakerVerification
        multichannel = profile.multichannel
        spatialSettings = profile.spatialSettings
        listener = profile.spatialListenerProfile
        acoustic = profile.spatialAcousticProfile
        contentMode = profile.spatialContentMode
        surroundLayout = profile.virtualSurroundLayout
        audioInterface = profile.audioInterface
        playbackMode = profile.playbackMode
        referenceCorrection = profile.personalReferenceCorrection
    }

    func restore(to profile: inout DeviceProfile) {
        profile.replaceProcessing(processing)
        profile.physicalChannelProcessing = physicalChannels
        profile.speakerTopology = topology
        profile.speakerTopologyNeedsReview = topologyNeedsReview
        profile.speakerVerification = verification
        profile.multichannel = multichannel
        profile.spatialSettings = spatialSettings
        profile.spatialListenerProfile = listener
        profile.spatialAcousticProfile = acoustic
        profile.spatialContentMode = contentMode
        profile.virtualSurroundLayout = surroundLayout
        profile.audioInterface = audioInterface
        profile.setPlaybackMode(playbackMode)
        profile.setPersonalReferenceCorrection(referenceCorrection)
    }
}

extension DeviceProfile {
    package var deviceTypeConfigurationKey: String {
        // Length-prefix the hardware UID so punctuation cannot alias contexts.
        "\(outputDeviceUID.utf8.count):\(outputDeviceUID):\(endpointKind.rawValue):\(endpointKind == .audioInterface ? effectiveEndpointKind.rawValue : "")"
    }

    package mutating func switchDeviceType(to type: ProfileEndpointKind,
                                           connectedEndpoint: ProfileEndpointKind? = nil,
                                           interfaceConfiguration: AudioInterfaceConfiguration? = nil) {
        let previous = self
        endpointKind = type
        if type == .audioInterface, audioInterface == nil { audioInterface = interfaceConfiguration }
        if type == .audioInterface, let connectedEndpoint {
            audioInterface?.connectedEndpoint = connectedEndpoint
        }
        guard deviceTypeConfigurationKey != previous.deviceTypeConfigurationKey else { return }
        deviceTypeConfigurations[previous.deviceTypeConfigurationKey] = ProfileDeviceConfiguration(previous)
        playbackModesByEndpoint[previous.endpointKind.rawValue] = previous.playbackMode
        if let saved = deviceTypeConfigurations[deviceTypeConfigurationKey] {
            saved.restore(to: &self)
        } else {
            // Manual global EQ/tone/limiting can be reused. Corrections, impulse
            // responses, delays and physical-channel tuning cannot.
            var reusable = previous.processing
            reusable.global.stages.removeAll { stage in
                if ProcessingProfile.isRoomStage(stage.id) { return true }
                switch stage.processor {
                case .deviceCorrection, .convolution, .crossfeed, .delay: return true
                case .gain, .equalizer, .limiter: return false
                }
            }
            if reusable.globalEqualizerProvenance != nil {
                reusable.setGlobalEqualizer(preampDB: 0, bands: [])
                reusable.globalEqualizerProvenance = nil
            }
            reusable.channels = ProcessingProfile().channels
            reusable.groups = []
            replaceProcessing(reusable)
            physicalChannelProcessing = [:]
            speakerTopology = nil
            speakerTopologyNeedsReview = false
            speakerVerification = nil
            multichannel = .init()
            spatialSettings = .init()
            spatialListenerProfile = nil
            spatialAcousticProfile = nil
            spatialContentMode = .automatic
            virtualSurroundLayout = .standard
            if effectiveEndpointKind == previous.effectiveEndpointKind { setPersonalReferenceCorrection(nil) }
            setPlaybackMode(.direct)
        }
        // Retain the last interface assignment as inactive setup metadata.
        if type != .audioInterface { audioInterface = previous.audioInterface }
        if !supportsCrossfeed { processing.setCrossfeed(nil) }
        if ![ProfileEndpointKind.headphones, .iem, .speakers].contains(effectiveEndpointKind) {
            setPlaybackMode(.direct)
        }
    }

    package var needsSpeakerConfiguration: Bool {
        guard effectiveEndpointKind == .speakers else { return false }
        guard !speakerTopologyNeedsReview, let topology = speakerTopology,
              topology.deviceUID == outputDeviceUID, topology.sampleRate == Double(sampleRate),
              (try? topology.validate()) != nil,
              let seat = effectiveSpatialSettings.seating,
              !seat.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              seat.leftDistanceMeters.isFinite, seat.leftDistanceMeters > 0,
              seat.rightDistanceMeters.isFinite, seat.rightDistanceMeters > 0 else { return true }
        let enabled = topology.endpoints.filter {
            $0.connectionState != .disabledByUser &&
                (endpointKind != .audioInterface || audioInterface?.hardware.enabledHardwareOutputs.contains($0.id.channelIndex) == true)
        }
        return enabled.isEmpty || !enabled.allSatisfy { $0.role != .unknown || $0.position != nil }
    }
}

package struct ProfileDeviceTypeDraft {
    package let original: DeviceProfile
    package var selectedType: ProfileEndpointKind

    package init(profile: DeviceProfile) {
        original = profile
        selectedType = profile.endpointKind
    }

    package func prepare(validate: (DeviceProfile) throws -> Void) throws -> DeviceProfile {
        var candidate = original
        candidate.switchDeviceType(to: selectedType)
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
    package var audioBufferOverride: AudioBufferSetting?
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
    private var configurationBaseline: DeviceProfile
    private var pendingConfigurations: [String: ProfileDeviceConfiguration] = [:]

    package init(profile: DeviceProfile, activation: ProfileActivationMode) {
        original = profile
        configurationBaseline = profile
        originalActivation = activation
        name = profile.name
        outputDevice = profile.outputDevice
        selectedType = profile.endpointKind
        sampleRate = profile.sampleRate
        audioBufferOverride = profile.audioBufferOverride
        self.activation = activation
        sectionLayout = profile.sectionLayout
        speakerTopology = profile.speakerTopology
        spatialSettings = profile.spatialSettings
        audioInterface = profile.audioInterface
    }
    package func candidate() throws -> DeviceProfile { try candidate(applyingTo: original) }

    /// Configuration editors must be able to display an incomplete new endpoint.
    package func preview() throws -> DeviceProfile { try candidate(applyingTo: original, validatingConfiguration: false) }

    package mutating func selectDeviceType(_ type: ProfileEndpointKind,
                                           connectedEndpoint: ProfileEndpointKind? = nil) throws {
        var next = try preview()
        guard next.endpointKind != type || (connectedEndpoint != nil && connectedEndpoint != next.effectiveEndpointKind) else { return }
        pendingConfigurations[next.deviceTypeConfigurationKey] = ProfileDeviceConfiguration(next)
        next.switchDeviceType(to: type, connectedEndpoint: connectedEndpoint)
        if let pending = pendingConfigurations[next.deviceTypeConfigurationKey] { pending.restore(to: &next) }
        configurationBaseline = next
        selectedType = type
        audioInterface = next.audioInterface
        speakerTopology = next.speakerTopology
        spatialSettings = next.spatialSettings
        requestedMode = nil
        processing = nil
        multichannel = nil
        speakerVerification = nil
    }

    package func candidate(applyingTo current: DeviceProfile, validatingConfiguration: Bool = true) throws -> DeviceProfile {
        guard current.id == original.id else { throw ProfileSettingsError.staleDraft }
        // Only fields edited in this session are owned. A conflicting edit to the
        // same field is rejected; unrelated mode/EQ/volume changes survive.
        func merge<T: Equatable>(_ old: T, _ edited: T, _ fresh: T) throws -> T {
            guard edited != old else { return fresh }
            guard fresh == old || fresh == edited else { throw ProfileSettingsError.staleDraft }
            return edited
        }
        var result = current
        let type = try merge(original.endpointKind, selectedType, current.endpointKind)
        let connected = type == .audioInterface
            ? try merge(original.audioInterface?.connectedEndpoint, audioInterface?.connectedEndpoint, current.audioInterface?.connectedEndpoint)
            : nil
        if type == current.endpointKind, connected == nil || connected == current.effectiveEndpointKind,
           outputDevice != original.outputDevice || audioInterface != original.audioInterface {
            result.captureLegacyPhysicalChannels()
        }
        result.switchDeviceType(to: type, connectedEndpoint: connected, interfaceConfiguration: audioInterface)
        for (key, edited) in pendingConfigurations {
            let old = key == original.deviceTypeConfigurationKey ? ProfileDeviceConfiguration(original) : original.deviceTypeConfigurations[key]
            let fresh = key == current.deviceTypeConfigurationKey ? ProfileDeviceConfiguration(current) : current.deviceTypeConfigurations[key]
            result.deviceTypeConfigurations[key] = try merge(old, Optional(edited), fresh)
        }
        if pendingConfigurations[result.deviceTypeConfigurationKey] != nil,
           let pending = result.deviceTypeConfigurations[result.deviceTypeConfigurationKey] { pending.restore(to: &result) }
        let baseline = configurationBaseline
        result.name = try merge(original.name, name.trimmingCharacters(in: .whitespacesAndNewlines), current.name)
        guard !result.name.isEmpty else { throw ProfileSettingsError.invalidName }
        result.outputDevice = try merge(original.outputDevice, outputDevice, current.outputDevice)
        result.sampleRate = try merge(original.sampleRate, sampleRate, current.sampleRate)
        result.audioBufferOverride = try merge(original.audioBufferOverride, audioBufferOverride, current.audioBufferOverride)
        if let frames = result.audioBufferOverride, frames != current.audioBufferOverride,
           !frames.isSupported {
            throw ProfileSettingsError.runtime("Choose a supported audio buffer size.")
        }
        result.sectionLayout = try merge(original.sectionLayout, sectionLayout, current.sectionLayout)
        result.speakerTopology = try merge(baseline.speakerTopology, speakerTopology, result.speakerTopology)
        if speakerTopology != baseline.speakerTopology, let topology = speakerTopology {
            try topology.validate()
            result.speakerTopologyNeedsReview = false
        }
        if sampleRate != original.sampleRate, result.speakerTopology?.deviceUID == result.outputDeviceUID {
            result.speakerTopology?.sampleRate = Double(result.sampleRate)
        }
        // Connected-device changes have already selected a separate context.
        var interfaceBaseline = baseline.audioInterface
        interfaceBaseline?.connectedEndpoint = audioInterface?.connectedEndpoint ?? .custom
        if audioInterface != interfaceBaseline {
            result.audioInterface = try merge(interfaceBaseline, audioInterface, result.audioInterface)
        }
        try result.migrateInterfaceTopology()
        if spatialSettings != baseline.spatialSettings {
            result.spatialSettings = try merge(baseline.spatialSettings, spatialSettings, result.spatialSettings)
            result.synchronizeListeningPositionCorrection()
        }
        if result.deviceTypeConfigurationKey != current.deviceTypeConfigurationKey,
           speakerTopology != baseline.speakerTopology,
           result.effectiveEndpointKind == .speakers, let topology = result.speakerTopology {
            result.speakerTopology = SpeakerLayoutGeometry.acceptingDefaultRoles(topology)
        }
        if validatingConfiguration, result.endpointKind == .audioInterface {
            guard result.audioInterface != nil else { throw ProfileSettingsError.runtime("Configure the interface channels before saving.") }
            _ = try result.validatedInterfaceConfiguration()
            _ = try result.validatedInterfaceOutputIndices()
        }
        if let requestedMode {
            _ = try merge(baseline.playbackMode, requestedMode, result.playbackMode)
            result.setPlaybackMode(requestedMode)
        }
        if let processing {
            result.replaceProcessing(try merge(baseline.processing, processing, result.processing))
        }
        if let speakerVerification {
            guard let topology = result.speakerTopology, speakerVerification.matches(topology) else { throw ProfileSettingsError.staleDraft }
            result.speakerVerification = speakerVerification
        }
        if let multichannel {
            result.multichannel = try merge(baseline.multichannel, multichannel, result.multichannel)
        }
        if let personalReferenceCorrections {
            result.personalReferenceCorrections = try merge(original.personalReferenceCorrections, personalReferenceCorrections, current.personalReferenceCorrections)
        }
        if validatingConfiguration, result.deviceTypeConfigurationKey != current.deviceTypeConfigurationKey,
           result.needsSpeakerConfiguration {
            throw ProfileSettingsError.runtime("Configure Speaker and Listening Position before saving this device type.")
        }
        return result
    }

}
