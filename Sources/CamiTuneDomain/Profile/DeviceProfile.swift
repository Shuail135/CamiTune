import Foundation

package struct DeviceProfile: Identifiable, Codable, Hashable, Sendable {
    package var id: UUID = UUID()
    package var name: String
    package var outputDevice: PhysicalOutputIdentity
    /// User-described use, independent of hardware identity and DSP selection.
    package var endpointKind: ProfileEndpointKind = .custom
    /// Inactive contexts retain their mode without duplicating shared DSP/geometry.
    package var physicalChannelProcessing: [PhysicalOutputID: ProcessingChain] = [:]
    package var speakerTopologyNeedsReview = false
    package var multichannel = MultichannelProcessingSettings()
    package var speakerVerification: SpeakerVerificationRecord?
    package var availableDeviceCorrectionPages: [DeviceCorrectionPage] {
        switch effectiveEndpointKind {
        case .headphones, .iem:
            return [.automaticEQ, .convolution] + (supportsCrossfeed ? [.crossfeed] : [])
        case .speakers: return [.automaticEQ, .convolution]
        case .audioInterface, .custom: return [.convolution]
        }
    }

    package var defaultSectionLayout: ProfileSectionLayout {
        var layout = ProfileSectionLayout()
        let advanced = hasPhysicalSpeakerRoute || (endpointKind == .audioInterface && configuredPhysicalChannelCount > 2)
        if !advanced { layout.hidden.insert(.perChannel) }
        return layout
    }

    package var personalReferenceCorrections: [String: DeviceCorrectionProfile] = [:]
    package var audioInterface: AudioInterfaceConfiguration?
    package var sectionLayout: ProfileSectionLayout?
    package var playbackModesByEndpoint: [String: PlaybackMode] = [:]
    package var isEnabled: Bool = true
    package var autoActivateWhenProfileDeviceSelected: Bool = false
    package var lockOutputVolume: Bool = false
    package var outputVolumeScalar: Double = 0.0625
    package var sampleRate: Int = 48_000
    package var chunkSize: Int = 1024
    package var playbackMode: PlaybackMode = .direct
    package var spatialRenderingMode: SpatialRenderingMode = .standard
    package var spatialSettings = SpatialRenderSettings()
    package var speakerTopology: SpeakerTopology?
    package var usesReferenceSpeakers: Bool {
        get { playbackMode == .referencePlayback && !isPersonalListening }
        set {
            if newValue { setPlaybackMode(.referencePlayback) }
            else if playbackMode == .referencePlayback { setPlaybackMode(.direct) }
        }
    }

    package var isPersonalListening: Bool { [.headphones, .iem].contains(effectiveEndpointKind) }

    package var effectiveEndpointKind: ProfileEndpointKind {
        endpointKind == .audioInterface ? (audioInterface?.connectedEndpoint ?? .custom) : endpointKind
    }

    package func validatedInterfaceConfiguration() throws -> AudioInterfaceConfiguration? {
        guard endpointKind == .audioInterface, let audioInterface else { return nil }
        try audioInterface.validate(deviceUID: outputDeviceUID)
        return audioInterface
    }

    package var availablePlaybackModes: [PlaybackMode] {
        var modes: [PlaybackMode]
        switch effectiveEndpointKind {
        case .headphones, .iem, .speakers:
            modes = [.direct, .referencePlayback, .spatialRender]
        case .audioInterface, .custom:
            // These require an endpoint assignment before enabling a renderer.
            modes = [.direct]
        }
        if !modes.contains(playbackMode) { modes.append(playbackMode) }
        return modes
    }

    package mutating func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
        spatialSettings.enabled = mode == .spatialRender
        spatialRenderingMode = mode == .spatialRender ? .spatialAudio : .standard
    }

    package var hasPhysicalSpeakerRoute: Bool {
        if endpointKind == .audioInterface && effectiveEndpointKind != .speakers { return false }
        return !isPersonalListening && speakerTopology != nil
    }
    package var configuredPhysicalChannelCount: Int {
        if hasPhysicalSpeakerRoute { return speakerTopology!.declaredChannelCount }
        return endpointKind == .audioInterface ? (audioInterface?.hardwareChannelCount ?? 2) : 2
    }
    package var processingChannelCount: Int { hasPhysicalSpeakerRoute ? configuredPhysicalChannelCount : 2 }
    package var supportsCrossfeed: Bool { isPersonalListening && processingChannelCount == 2 }

    package var personalReferenceCorrection: DeviceCorrectionProfile? {
        personalReferenceCorrections[effectiveEndpointKind.rawValue]
    }
    package mutating func setPersonalReferenceCorrection(_ correction: DeviceCorrectionProfile?) {
        personalReferenceCorrections[effectiveEndpointKind.rawValue] = correction
    }

    package func playbackReadiness(_ mode: PlaybackMode) -> PlaybackModeReadiness {
        if usesSourceProcessingBus && mode != .direct { return .unavailable("Bass management, custom routing and active crossovers currently use Direct playback.") }
        if speakerTopologyNeedsReview { return .unavailable("Review the speaker setup before using this profile.") }
        guard availablePlaybackModes.contains(mode) else { return .unavailable("This mode is not supported by the connected device type.") }
        if [.custom, .audioInterface].contains(effectiveEndpointKind), mode != .direct {
            return .unavailable("Choose the connected device type in Profile Settings before using this mode.")
        }
        if endpointKind == .audioInterface {
            guard audioInterface != nil, (try? validatedInterfaceConfiguration()) != nil else { return .unavailable("Configure the interface channels in Profile Settings.") }
        }
        if hasPhysicalSpeakerRoute {
            do { _ = try validatedPhysicalSpeakerTopology() } catch { return .unavailable(error.localizedDescription) }
        } else if mode == .referencePlayback && !isPersonalListening {
            return .unavailable("Configure Speaker and Listening Position in Profile Settings.")
        }
        if mode == .referencePlayback && !isPersonalListening {
            var candidate = self; candidate.setPlaybackMode(mode)
            do { _ = try candidate.validatedReferenceTopology() } catch { return .unavailable(error.localizedDescription) }
        }
        if mode == .referencePlayback && isPersonalListening {
            guard let correction = personalReferenceCorrection else {
                return .unavailable("Load Reference correction filters first.")
            }
            guard correction.schemaVersion == DeviceCorrectionProfile.currentSchemaVersion,
                  ReferenceCorrection.validFilters(correction.filters, sampleRate: Double(sampleRate)) else {
                return .unavailable("Reference correction contains unsupported or invalid filters.")
            }
        }
        return .ready
    }

    package func validatedPhysicalSpeakerTopology() throws -> SpeakerTopology? {
        guard !speakerTopologyNeedsReview else {
            throw ProfileSettingsError.runtime("The saved speaker setup could not be read. Review Speakers before activating this profile.")
        }
        guard hasPhysicalSpeakerRoute else { return nil }
        guard var topology = speakerTopology else { return nil }
        guard topology.deviceUID == outputDeviceUID else { throw SpeakerTopologyError.invalidDeviceUID }
        try topology.validate()
        guard topology.sampleRate == Double(sampleRate) else { throw SpeakerTopologyError.invalidSampleRate }
        if let assignment = try validatedInterfaceConfiguration() {
            for index in topology.endpoints.indices where !assignment.hardware.enabledHardwareOutputs.contains(topology.endpoints[index].id.channelIndex) {
                topology.endpoints[index].connectionState = .disabledByUser
            }
        }
        return SpeakerLayoutGeometry.relativeTopology(topology, seat: effectiveSpatialSettings.seating)
    }

    package func validatedReferenceTopology() throws -> SpeakerTopology? {
        guard usesReferenceSpeakers else { return nil }
        guard let topology = speakerTopology else {
            throw ProfileSettingsError.runtime("Configure Speaker and Listening Position in Profile Settings before using Reference.")
        }
        guard topology.deviceUID == outputDeviceUID else { throw SpeakerTopologyError.invalidDeviceUID }
        try topology.validate()
        guard topology.sampleRate == Double(sampleRate) else { throw SpeakerTopologyError.invalidSampleRate }
        guard topology.endpoints.contains(where: { ($0.connectionState == .confirmedByUser || $0.connectionState == .acousticallyDetected) && ($0.role != .unknown || $0.position != nil) }) else {
            throw ProfileSettingsError.runtime("Configure Speaker and Listening Position in Profile Settings before using Reference.")
        }
        return try validatedPhysicalSpeakerTopology()
    }

    package var effectiveSpatialSettings: SpatialRenderSettings {
        var settings = spatialSettings
        switch effectiveEndpointKind {
        case .headphones, .iem: settings.outputSelection = .headphones
        case .speakers: settings.outputSelection = .speakers
        case .audioInterface, .custom: settings.outputSelection = .speakers
        }
        if settings.seating?.outputDeviceUID != outputDeviceUID { settings.seating = nil }
        if settings.seating == nil {
            settings.selectedPositionID = settings.listeningPositions.first { $0.id == settings.primaryPositionID && $0.outputDeviceUID == outputDeviceUID }?.id
                ?? settings.listeningPositions.first { $0.outputDeviceUID == outputDeviceUID }?.id
        }
        return settings
    }
    package var effectiveSpatialRenderingMode: SpatialRenderingMode {
        playbackMode == .spatialRender ? .spatialAudio : .standard
    }
    package var spatialContentMode: SpatialContentMode = .automatic
    package var virtualSurroundLayout: VirtualSurroundLayout = .standard
    package var spatialListenerProfile: SpatialListenerProfile?
    package var spatialAcousticProfile: SpatialAcousticProfile?

    /// Only the managed room-correction stage follows the selected seat. User EQ,
    /// device correction and limiter stages retain their identity and settings.
    package mutating func synchronizeListeningPositionCorrection() {
        let bands = effectiveSpatialSettings.seating?.roomCorrectionBands ?? []
        processing.global.stages.removeAll { $0.id == ProcessingProfile.spatialRoomCorrectionStageID }
        if !bands.isEmpty {
            processing.global.stages.append(ProcessingStage(id: ProcessingProfile.spatialRoomCorrectionStageID,
                processor: .equalizer(EqualizerProcessor(bands: bands))))
        }
    }

    package var spatialListenerTuning: SpatialListenerTuning {
        spatialListenerProfile?.tuning(for: outputDeviceUID)
            ?? (spatialAcousticProfile?.applies(to: self) == true ? spatialAcousticProfile!.suggestedTuning : .neutral)
    }
    package var processing: ProcessingProfile
    private var unmigratedEqualizerAPOText: String?

    package init(
        id: UUID = UUID(),
        name: String,
        outputDeviceUID: String,
        outputDeviceName: String,
        isEnabled: Bool = true,
        autoActivateWhenProfileDeviceSelected: Bool = false,
        lockOutputVolume: Bool = false,
        outputVolumeScalar: Double = 0.0625,
        sampleRate: Int = 48_000,
        chunkSize: Int = 1024,
        spatialRenderingMode: SpatialRenderingMode = .standard,
        equalizerAPOText: String = DeviceProfile.defaultEqualizerAPOText,
        processing: ProcessingProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.outputDevice = PhysicalOutputIdentity(uid: outputDeviceUID, name: outputDeviceName)
        self.isEnabled = isEnabled
        self.autoActivateWhenProfileDeviceSelected = autoActivateWhenProfileDeviceSelected
        self.lockOutputVolume = lockOutputVolume
        self.outputVolumeScalar = outputVolumeScalar
        self.sampleRate = sampleRate
        self.chunkSize = chunkSize
        self.spatialRenderingMode = spatialRenderingMode
        self.spatialSettings = .migrated(from: spatialRenderingMode)
        self.playbackMode = spatialRenderingMode == .standard ? .direct : .spatialRender
        if let processing {
            self.processing = processing
            self.unmigratedEqualizerAPOText = nil
        } else if let parsed = try? Self.parseImportableEqualizerAPOText(equalizerAPOText) {
            self.processing = ProcessingProfile.imported(from: parsed)
            self.unmigratedEqualizerAPOText = nil
        } else {
            self.processing = .defaultStereo
            self.unmigratedEqualizerAPOText = equalizerAPOText
        }
    }

    package var outputDeviceUID: String {
        get { outputDevice.uid }
        set { outputDevice.uid = newValue }
    }

    package var outputDeviceName: String {
        get { outputDevice.name }
        set { outputDevice.name = newValue }
    }

    /// Compatibility surface for Equalizer APO import/export. ProcessingProfile
    /// remains authoritative once the text parses successfully.
    package var equalizerAPOText: String {
        get {
            unmigratedEqualizerAPOText
                ?? EqualizerAPOSerializer().serialize(processing.globalEqualizer)
        }
        set {
            if let parsed = try? Self.parseImportableEqualizerAPOText(newValue) {
                setGlobalEqualizer(
                    preampDB: parsed.preampDB,
                    bands: parsed.bands
                )
            } else {
                unmigratedEqualizerAPOText = newValue
            }
        }
    }

    package mutating func replaceProcessing(_ value: ProcessingProfile) {
        processing = value
        unmigratedEqualizerAPOText = nil
    }

    package mutating func setGlobalEqualizer(preampDB: Double, bands: [EQBand]) {
        processing.setGlobalEqualizer(preampDB: preampDB, bands: bands)
        unmigratedEqualizerAPOText = nil
    }

    package mutating func setChannelProcessing(
        index: Int,
        role: ChannelRole,
        gainDB: Double,
        bands: [EQBand],
        delayMilliseconds: Double? = nil,
        limiterEnabled: Bool? = nil,
        simpleTone: SimpleToneSettings? = nil
    ) throws {
        captureLegacyPhysicalChannels()
        processing = try resolvedProcessing()
        processing.setChannelProcessing(
            index: index,
            role: role,
            gainDB: gainDB,
            bands: bands,
            delayMilliseconds: delayMilliseconds,
            limiterEnabled: limiterEnabled,
            simpleTone: simpleTone
        )
        if let physical = configuredProcessingChannels.first(where: { $0.index == index })?.physicalOutputID,
           let channel = processing.channels.first(where: { $0.index == index }) { physicalChannelProcessing[physical] = channel.chain }
        unmigratedEqualizerAPOText = nil
    }

    package func resolvedProcessing() throws -> ProcessingProfile {
        if let text = unmigratedEqualizerAPOText {
            return ProcessingProfile.imported(from: try Self.parseImportableEqualizerAPOText(text))
        }
        var result = processing
        if !physicalChannelProcessing.isEmpty {
            result.channels = configuredProcessingChannels.map { channel in
                ChannelProcessing(index: channel.index, role: channel.role,
                    chain: physicalChannelProcessing[channel.physicalOutputID] ?? ProcessingChain())
            }
        }
        return result
    }

    private static func parseImportableEqualizerAPOText(_ text: String) throws -> ParsedEQ {
        let parsed = try EqualizerAPOParser().parse(text)
        guard parsed.importedDirectiveCount > 0 else {
            throw EqualizerAPOParser.ParseError(
                line: 1,
                message: "The Equalizer APO document has no processing CamiTune can import yet"
            )
        }
        return parsed
    }

    private static let defaultEqualizerAPOText = """
Preamp: 0.0 dB
Filter 1: ON LS Fc 31 Hz Gain 0.0 dB Q 1.00
Filter 2: ON PK Fc 76 Hz Gain 0.0 dB Q 1.00
Filter 3: ON PK Fc 184 Hz Gain 0.0 dB Q 1.00
Filter 4: ON PK Fc 447 Hz Gain 0.0 dB Q 1.00
Filter 5: ON PK Fc 1087 Hz Gain 0.0 dB Q 1.00
Filter 6: ON PK Fc 2643 Hz Gain 0.0 dB Q 1.00
Filter 7: ON PK Fc 6423 Hz Gain 0.0 dB Q 1.00
Filter 8: ON HS Fc 16000 Hz Gain 0.0 dB Q 1.00
"""

    private enum CodingKeys: String, CodingKey {
        case id, name, outputDevice, outputDeviceUID, outputDeviceName, isEnabled, endpointKind
        case autoActivateWhenProfileDeviceSelected, playbackModesByEndpoint, sectionLayout, audioInterface, personalReferenceCorrections, physicalChannelProcessing, speakerTopologyNeedsReview
        case lockOutputVolume, outputVolumeScalar, sampleRate, chunkSize, playbackMode
        case spatialRenderingMode, spatialContentMode, spatialListenerProfile, spatialAcousticProfile, equalizerAPOText, processing
        case virtualSurroundLayout, spatialSettings, speakerTopology, usesReferenceSpeakers, multichannel, speakerVerification
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case autoActivateWhenSystemAudioBridgeSelected
        case autoActivateWhenBlackHoleSelected
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        if let decodedOutput = try values.decodeIfPresent(PhysicalOutputIdentity.self, forKey: .outputDevice) {
            outputDevice = decodedOutput
        } else {
            outputDevice = PhysicalOutputIdentity(
                uid: try values.decode(String.self, forKey: .outputDeviceUID),
                name: try values.decode(String.self, forKey: .outputDeviceName)
            )
        }
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        endpointKind = try values.decodeIfPresent(ProfileEndpointKind.self, forKey: .endpointKind) ?? .custom
        multichannel = try values.decodeIfPresent(MultichannelProcessingSettings.self, forKey: .multichannel) ?? .init()
        speakerVerification = try values.decodeIfPresent(SpeakerVerificationRecord.self, forKey: .speakerVerification)
        physicalChannelProcessing = try values.decodeIfPresent([PhysicalOutputID: ProcessingChain].self, forKey: .physicalChannelProcessing) ?? [:]
        for id in physicalChannelProcessing.keys { try id.validate() }
        personalReferenceCorrections = try values.decodeIfPresent([String: DeviceCorrectionProfile].self, forKey: .personalReferenceCorrections) ?? [:]
        audioInterface = try values.decodeIfPresent(AudioInterfaceConfiguration.self, forKey: .audioInterface)
        sectionLayout = try values.decodeIfPresent(ProfileSectionLayout.self, forKey: .sectionLayout)
        playbackModesByEndpoint = try values.decodeIfPresent(
            [String: PlaybackMode].self, forKey: .playbackModesByEndpoint) ?? [:]
        autoActivateWhenProfileDeviceSelected = try values.decodeIfPresent(
            Bool.self,
            forKey: .autoActivateWhenProfileDeviceSelected
        ) ?? legacy.decodeIfPresent(
            Bool.self,
            forKey: .autoActivateWhenSystemAudioBridgeSelected
        ) ?? legacy.decodeIfPresent(Bool.self, forKey: .autoActivateWhenBlackHoleSelected) ?? false
        lockOutputVolume = try values.decodeIfPresent(Bool.self, forKey: .lockOutputVolume) ?? false
        outputVolumeScalar = try values.decodeIfPresent(Double.self, forKey: .outputVolumeScalar) ?? 0.0625
        sampleRate = try values.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
        chunkSize = try values.decodeIfPresent(Int.self, forKey: .chunkSize) ?? 1024
        spatialRenderingMode = try values.decodeIfPresent(
            SpatialRenderingMode.self,
            forKey: .spatialRenderingMode
        ) ?? .standard
        speakerTopologyNeedsReview = try values.decodeIfPresent(Bool.self, forKey: .speakerTopologyNeedsReview) ?? false
        do {
            speakerTopology = try values.decodeIfPresent(SpeakerTopology.self, forKey: .speakerTopology)
            try speakerTopology?.validate()
        } catch {
            speakerTopology = nil
            speakerTopologyNeedsReview = true
        }
        let legacyUsesReferenceSpeakers =
            (try? values.decodeIfPresent(Bool.self, forKey: .usesReferenceSpeakers)) ?? false
        // Preserve intent on stale device/rate mappings; activation surfaces the
        // mismatch rather than silently playing with an old physical map.
        spatialSettings = try values.decodeIfPresent(SpatialRenderSettings.self, forKey: .spatialSettings)
            ?? .migrated(from: spatialRenderingMode)
        if spatialRenderingMode == .frontStage || spatialRenderingMode == .virtualSurround {
            spatialSettings.enabled = true
        }
        if let decodedMode = try values.decodeIfPresent(PlaybackMode.self, forKey: .playbackMode) {
            playbackMode = decodedMode
        } else if legacyUsesReferenceSpeakers {
            playbackMode = .referencePlayback
        } else if spatialSettings.enabled || spatialRenderingMode != .standard {
            playbackMode = .spatialRender
        } else {
            playbackMode = .direct
        }
        spatialSettings.enabled = playbackMode == .spatialRender
        spatialRenderingMode = playbackMode == .spatialRender ? .spatialAudio : .standard
        // A damaged or newer optional calibration must not make an otherwise
        // usable output/EQ profile unreadable.
        spatialListenerProfile = try? values.decodeIfPresent(
            SpatialListenerProfile.self, forKey: .spatialListenerProfile
        )
        spatialAcousticProfile = try? values.decodeIfPresent(SpatialAcousticProfile.self, forKey: .spatialAcousticProfile)
        spatialContentMode = (try? values.decodeIfPresent(SpatialContentMode.self, forKey: .spatialContentMode)) ?? .automatic
        virtualSurroundLayout = (try? values.decodeIfPresent(VirtualSurroundLayout.self, forKey: .virtualSurroundLayout)) ?? .standard
        let legacyText = try values.decodeIfPresent(String.self, forKey: .equalizerAPOText)
            ?? Self.defaultEqualizerAPOText
        if let decodedProcessing = try values.decodeIfPresent(ProcessingProfile.self, forKey: .processing) {
            processing = decodedProcessing
            unmigratedEqualizerAPOText = nil
        } else if let parsed = try? Self.parseImportableEqualizerAPOText(legacyText) {
            processing = ProcessingProfile.imported(from: parsed)
            unmigratedEqualizerAPOText = nil
        } else {
            processing = .defaultStereo
            unmigratedEqualizerAPOText = legacyText
        }
        if let stage = processing.global.stages.first(where: { $0.id == ProcessingProfile.spatialRoomCorrectionStageID }),
           case .equalizer(let eq) = stage.processor,
           spatialSettings.seating?.roomCorrectionBands.isEmpty != false {
            var seat = spatialSettings.seating ?? SpatialSeatingCalibration(outputDeviceUID: outputDeviceUID,
                name: spatialListenerProfile?.name ?? "Existing room calibration")
            seat.roomCorrectionBands = eq.bands
            spatialSettings.seating = seat
        }
        do { try migrateInterfaceTopology() }
        catch { speakerTopologyNeedsReview = true }
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(outputDevice, forKey: .outputDevice)
        try values.encode(endpointKind, forKey: .endpointKind)
        try values.encode(multichannel, forKey: .multichannel)
        try values.encodeIfPresent(speakerVerification, forKey: .speakerVerification)
        try values.encode(playbackModesByEndpoint, forKey: .playbackModesByEndpoint)
        try values.encodeIfPresent(sectionLayout, forKey: .sectionLayout)
        try values.encodeIfPresent(audioInterface, forKey: .audioInterface)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(autoActivateWhenProfileDeviceSelected, forKey: .autoActivateWhenProfileDeviceSelected)
        try values.encode(lockOutputVolume, forKey: .lockOutputVolume)
        try values.encode(outputVolumeScalar, forKey: .outputVolumeScalar)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(chunkSize, forKey: .chunkSize)
        try values.encode(playbackMode, forKey: .playbackMode)
        try values.encode(spatialRenderingMode, forKey: .spatialRenderingMode)
        try values.encode(spatialSettings, forKey: .spatialSettings)
        try values.encodeIfPresent(speakerTopology, forKey: .speakerTopology)
        try values.encode(usesReferenceSpeakers, forKey: .usesReferenceSpeakers)
        try values.encode(personalReferenceCorrections, forKey: .personalReferenceCorrections)
        try values.encode(physicalChannelProcessing, forKey: .physicalChannelProcessing)
        try values.encode(speakerTopologyNeedsReview, forKey: .speakerTopologyNeedsReview)
        try values.encodeIfPresent(spatialListenerProfile, forKey: .spatialListenerProfile)
        try values.encodeIfPresent(spatialAcousticProfile, forKey: .spatialAcousticProfile)
        try values.encode(spatialContentMode, forKey: .spatialContentMode)
        try values.encode(virtualSurroundLayout, forKey: .virtualSurroundLayout)
        // Do not let a placeholder graph overwrite an invalid legacy document.
        // Keeping it unmigrated means the editor can still surface and repair it.
        if unmigratedEqualizerAPOText == nil {
            try values.encode(processing, forKey: .processing)
        }
        try values.encode(equalizerAPOText, forKey: .equalizerAPOText)
    }
}

package struct ConfiguredProcessingChannel: Identifiable, Hashable {
    package init(index: Int, role: ChannelRole, physicalOutputID: PhysicalOutputID, displayName: String) {
        self.index = index
        self.role = role
        self.physicalOutputID = physicalOutputID
        self.displayName = displayName
    }

    package var index: Int
    package var role: ChannelRole
    package var physicalOutputID: PhysicalOutputID
    package var displayName: String
    package var id: PhysicalOutputID { physicalOutputID }
}

extension PlaybackMode {
    package var compactDisplayName: String {
        switch self {
        case .direct: return "Direct"
        case .referencePlayback: return "Reference"
        case .spatialRender: return "Spatial"
        }
    }

    package var systemImageName: String {
        switch self {
        case .direct: return "waveform.circle"
        case .referencePlayback: return "headphones"
        case .spatialRender: return "tv.music.note"
        }
    }

    package var displayName: String {
        compactDisplayName
    }
}

extension DeviceProfile {
    package mutating func captureLegacyPhysicalChannels() {
        guard physicalChannelProcessing.isEmpty else { return }
        for channel in processing.channels {
            let index: Int
            if endpointKind == .audioInterface, !hasPhysicalSpeakerRoute, let outputs = interfaceStereoOutputIndices,
               outputs.indices.contains(channel.index) { index = outputs[channel.index] }
            else { index = channel.index }
            physicalChannelProcessing[PhysicalOutputID(deviceUID: outputDeviceUID, channelIndex: index)] = channel.chain
        }
    }
}

extension DeviceProfile {
    package var configuredProcessingChannels: [ConfiguredProcessingChannel] {
        if hasPhysicalSpeakerRoute, let topology = speakerTopology {
            return topology.endpoints.filter {
                ($0.connectionState == .confirmedByUser || $0.connectionState == .acousticallyDetected)
                    && (endpointKind != .audioInterface || audioInterface?.hardware.enabledHardwareOutputs.contains($0.id.channelIndex) == true)
            }.sorted { $0.id.channelIndex < $1.id.channelIndex }.map {
                ConfiguredProcessingChannel(index: $0.id.channelIndex, role: $0.role,
                    physicalOutputID: $0.id, displayName: $0.displayName)
            }
        }
        let assignment = endpointKind == .audioInterface ? interfaceStereoOutputIndices : nil
        return (0..<min(2, assignment?.count ?? 2)).map { index in
            let physical = assignment?[index] ?? index
            return ConfiguredProcessingChannel(index: index, role: index == 0 ? .left : .right,
                physicalOutputID: PhysicalOutputID(deviceUID: outputDeviceUID, channelIndex: physical),
                displayName: "Channel \(physical + 1)")
        }
    }
}
