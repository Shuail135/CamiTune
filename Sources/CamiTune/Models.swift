import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String          // CoreAudio UID
    let objectID: UInt32
    let name: String
    let transportType: UInt32

    static let systemAudioBridgeName = "System Audio Bridge"
    static let systemAudioBridgeUID = "local.systemaudiobridge.device"

    init(id: String, objectID: UInt32, name: String, transportType: UInt32 = 0) {
        self.id = id
        self.objectID = objectID
        self.name = name
        self.transportType = transportType
    }

    var isRoutingDevice: Bool {
        id == Self.systemAudioBridgeUID ||
            ProfileRoutingDescriptor.isProfileRoutingUID(id) ||
            transportType == kAudioDeviceTransportTypeAggregate ||
            transportType == kAudioDeviceTransportTypeVirtual
    }
}

struct PhysicalOutputIdentity: Identifiable, Codable, Hashable, Sendable {
    var uid: String
    var name: String

    var id: String { uid }
}

struct PhysicalDeviceDefaultProfile: Identifiable, Codable, Hashable, Sendable {
    var physicalDevice: PhysicalOutputIdentity
    var profileID: UUID

    var id: String { physicalDevice.uid }
}

enum ProfileEndpointKind: String, Codable, CaseIterable, Sendable {
    case headphones, iem, speakers, audioInterface, custom

    var displayName: String {
        switch self {
        case .headphones: return "Headphones"
        case .iem: return "In-ear Earphone (IEM)"
        case .speakers: return "Speakers"
        case .audioInterface: return "Audio Interface"
        case .custom: return "Custom / Unspecified"
        }
    }
}

enum ProfileActivationMode: Hashable, Sendable {
    case physicalOutput, profileAudioDevice, manual
}

enum PlaybackMode: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case referencePlayback
    case spatialRender

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "normal" { self = .direct; return }
        guard let mode = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unsupported playback mode: \(value)")
        }
        self = mode
    }

    var compactDisplayName: String {
        switch self {
        case .direct: return "Direct"
        case .referencePlayback: return "Reference"
        case .spatialRender: return "Spatial"
        }
    }

    var systemImageName: String {
        switch self {
        case .direct: return "waveform.circle"
        case .referencePlayback: return "headphones"
        case .spatialRender: return "tv.music.note"
        }
    }

    var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .referencePlayback: return "Reference Playback"
        case .spatialRender: return "Spatial Render"
        }
    }
}

struct DeviceProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var outputDevice: PhysicalOutputIdentity
    /// User-described use, independent of hardware identity and DSP selection.
    var endpointKind: ProfileEndpointKind = .custom
    /// Inactive contexts retain their mode without duplicating shared DSP/geometry.
    var audioInterface: AudioInterfaceConfiguration?
    var sectionLayout: ProfileSectionLayout?
    var playbackModesByEndpoint: [String: PlaybackMode] = [:]
    var isEnabled: Bool = true
    var autoActivateWhenProfileDeviceSelected: Bool = false
    var lockOutputVolume: Bool = false
    var outputVolumeScalar: Double = 0.0625
    var sampleRate: Int = 48_000
    var chunkSize: Int = 1024
    var playbackMode: PlaybackMode = .direct
    var spatialRenderingMode: SpatialRenderingMode = .standard
    var spatialSettings = SpatialRenderSettings()
    var speakerTopology: SpeakerTopology?
    var usesReferenceSpeakers: Bool {
        get { playbackMode == .referencePlayback && !isPersonalListening }
        set {
            if newValue { setPlaybackMode(.referencePlayback) }
            else if playbackMode == .referencePlayback { setPlaybackMode(.direct) }
        }
    }

    var isPersonalListening: Bool { [.headphones, .iem].contains(effectiveEndpointKind) }

    var effectiveEndpointKind: ProfileEndpointKind {
        endpointKind == .audioInterface ? (audioInterface?.connectedEndpoint ?? .custom) : endpointKind
    }

    func validatedInterfaceConfiguration() throws -> AudioInterfaceConfiguration? {
        guard endpointKind == .audioInterface, let audioInterface else { return nil }
        try audioInterface.validate(deviceUID: outputDeviceUID)
        return audioInterface
    }

    var availablePlaybackModes: [PlaybackMode] {
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

    mutating func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
        spatialSettings.enabled = mode == .spatialRender
        spatialRenderingMode = mode == .spatialRender ? .spatialAudio : .standard
    }

    var processingChannelCount: Int {
        usesReferenceSpeakers ? (speakerTopology?.declaredChannelCount ?? 2) : 2
    }

    func validatedReferenceTopology() throws -> SpeakerTopology? {
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
        return SpeakerLayoutGeometry.relativeTopology(topology, seat: effectiveSpatialSettings.seating)
    }

    var effectiveSpatialSettings: SpatialRenderSettings {
        var settings = spatialSettings
        switch effectiveEndpointKind {
        case .headphones, .iem: settings.outputSelection = .headphones
        case .speakers: settings.outputSelection = .speakers
        case .audioInterface, .custom: break
        }
        if settings.seating?.outputDeviceUID != outputDeviceUID { settings.seating = nil }
        if settings.seating == nil {
            settings.selectedPositionID = settings.listeningPositions.first { $0.outputDeviceUID == outputDeviceUID }?.id
        }
        return settings
    }
    var effectiveSpatialRenderingMode: SpatialRenderingMode {
        playbackMode == .spatialRender ? .spatialAudio : .standard
    }
    var spatialContentMode: SpatialContentMode = .automatic
    var virtualSurroundLayout: VirtualSurroundLayout = .standard
    var spatialListenerProfile: SpatialListenerProfile?
    var spatialAcousticProfile: SpatialAcousticProfile?

    /// Only the managed room-correction stage follows the selected seat. User EQ,
    /// device correction and limiter stages retain their identity and settings.
    mutating func synchronizeListeningPositionCorrection() {
        let bands = effectiveSpatialSettings.seating?.roomCorrectionBands ?? []
        processing.global.stages.removeAll { $0.id == SpatialRoomCorrection.stageID }
        if !bands.isEmpty {
            processing.global.stages.append(ProcessingStage(id: SpatialRoomCorrection.stageID,
                processor: .equalizer(EqualizerProcessor(bands: bands))))
        }
    }

    var spatialListenerTuning: SpatialListenerTuning {
        spatialListenerProfile?.tuning(for: outputDeviceUID)
            ?? (spatialAcousticProfile?.applies(to: self) == true ? spatialAcousticProfile!.suggestedTuning : .neutral)
    }
    var processing: ProcessingProfile
    private var unmigratedEqualizerAPOText: String?

    init(
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

    var outputDeviceUID: String {
        get { outputDevice.uid }
        set { outputDevice.uid = newValue }
    }

    var outputDeviceName: String {
        get { outputDevice.name }
        set { outputDevice.name = newValue }
    }

    /// Compatibility surface for Equalizer APO import/export. ProcessingProfile
    /// remains authoritative once the text parses successfully.
    var equalizerAPOText: String {
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

    mutating func replaceProcessing(_ value: ProcessingProfile) {
        processing = value
        unmigratedEqualizerAPOText = nil
    }

    mutating func setGlobalEqualizer(preampDB: Double, bands: [EQBand]) {
        processing.setGlobalEqualizer(preampDB: preampDB, bands: bands)
        unmigratedEqualizerAPOText = nil
    }

    mutating func setChannelProcessing(
        index: Int,
        role: ChannelRole,
        gainDB: Double,
        bands: [EQBand],
        delayMilliseconds: Double? = nil,
        limiterEnabled: Bool? = nil
    ) throws {
        processing = try resolvedProcessing()
        processing.setChannelProcessing(
            index: index,
            role: role,
            gainDB: gainDB,
            bands: bands,
            delayMilliseconds: delayMilliseconds,
            limiterEnabled: limiterEnabled
        )
        unmigratedEqualizerAPOText = nil
    }

    func resolvedProcessing() throws -> ProcessingProfile {
        if let text = unmigratedEqualizerAPOText {
            return ProcessingProfile.imported(from: try Self.parseImportableEqualizerAPOText(text))
        }
        return processing
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
        case autoActivateWhenProfileDeviceSelected, playbackModesByEndpoint, sectionLayout, audioInterface
        case lockOutputVolume, outputVolumeScalar, sampleRate, chunkSize, playbackMode
        case spatialRenderingMode, spatialContentMode, spatialListenerProfile, spatialAcousticProfile, equalizerAPOText, processing
        case virtualSurroundLayout, spatialSettings, speakerTopology, usesReferenceSpeakers
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case autoActivateWhenSystemAudioBridgeSelected
        case autoActivateWhenBlackHoleSelected
    }

    init(from decoder: Decoder) throws {
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
        speakerTopology = try? values.decodeIfPresent(SpeakerTopology.self, forKey: .speakerTopology)
        if let topology = speakerTopology, (try? topology.validate()) == nil { speakerTopology = nil }
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
        if let stage = processing.global.stages.first(where: { $0.id == SpatialRoomCorrection.stageID }),
           case .equalizer(let eq) = stage.processor,
           spatialSettings.seating?.roomCorrectionBands.isEmpty != false {
            var seat = spatialSettings.seating ?? SpatialSeatingCalibration(outputDeviceUID: outputDeviceUID,
                name: spatialListenerProfile?.name ?? "Existing room calibration")
            seat.roomCorrectionBands = eq.bands
            spatialSettings.seating = seat
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(outputDevice, forKey: .outputDevice)
        try values.encode(endpointKind, forKey: .endpointKind)
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

struct EQBand: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case peaking
        case lowShelf
        case highShelf
        case lowPass
        case highPass
        case notch
        case allPass
    }

    let id: UUID
    var enabled: Bool
    var kind: Kind
    var frequency: Double
    var gain: Double?
    var q: Double?
    var bandwidth: Double?

    init(id: UUID = UUID(), enabled: Bool = true, kind: Kind, frequency: Double, gain: Double? = nil, q: Double? = nil, bandwidth: Double? = nil) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.bandwidth = bandwidth
    }
}

struct ParsedEQ: Sendable {
    var preampDB: Double = 0
    var bands: [EQBand] = []
    var warnings: [String] = []
    /// Number of Preamp/filter directives actually represented in this graph.
    /// Metadata and recognized-but-unsupported APO commands do not increment it.
    var importedDirectiveCount: Int = 0
}

struct SpectrumPoint: Identifiable {
    let frequency: Double
    let db: Double
    var id: Double { frequency }
}

/// Pure settings preflight. The runtime owner must apply the returned candidate
/// successfully before persisting it; abandoning a draft never changes the source.
struct ProfileDeviceTypeDraft {
    let original: DeviceProfile
    var selectedType: ProfileEndpointKind

    init(profile: DeviceProfile) {
        original = profile
        selectedType = profile.endpointKind
    }

    func prepare(validate: (DeviceProfile) throws -> Void) throws -> DeviceProfile {
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

// Presentation preferences are separate from processing and routing identity.
enum ProfileSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case deviceSetup, meters, spectrum, mode, equalizer, convolution, crossfeed, perChannel
    var id: Self { self }
    var title: String {
        switch self {
        case .deviceSetup: return "Device Setup"
        case .meters: return "Meters & Status"
        case .spectrum: return "Spectrum"
        case .mode: return "Mode"
        case .equalizer: return "Equalizer"
        case .convolution: return "FIR / Convolution"
        case .crossfeed: return "Headphone Crossfeed"
        case .perChannel: return "Per-channel EQ, Gain & Delay"
        }
    }
    func applies(to type: ProfileEndpointKind) -> Bool {
        self != .crossfeed || type == .headphones || type == .iem || type == .custom || type == .audioInterface
    }
}

enum EqualizerPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case simpleTone, bands, both
    var id: Self { self }
    var title: String { self == .bands ? "Bands" : self == .simpleTone ? "Simple Tone" : "Both" }
}

struct SectionPresentationPreference: Codable, Hashable, Sendable {
    var equalizer: EqualizerPresentation = .both
}

struct ProfileSectionLayout: Codable, Hashable, Sendable {
    var order: [ProfileSection] = ProfileSection.allCases
    var hidden: Set<ProfileSection> = []
    var presentation: [String: SectionPresentationPreference] = [:]

    private enum CodingKeys: String, CodingKey { case order, hidden, presentation }
    init(order: [ProfileSection] = ProfileSection.allCases, hidden: Set<ProfileSection> = [],
         presentation: [String: SectionPresentationPreference] = [:]) {
        self.order = order
        self.hidden = hidden
        self.presentation = presentation
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([ProfileSection].self, forKey: .order) ?? ProfileSection.allCases
        hidden = try values.decodeIfPresent(Set<ProfileSection>.self, forKey: .hidden) ?? []
        presentation = try values.decodeIfPresent([String: SectionPresentationPreference].self, forKey: .presentation) ?? [:]
    }
    func visualDemand(for type: ProfileEndpointKind) -> (meters: Bool, spectrum: Bool) {
        let sections = visibleSections(for: type)
        return (sections.contains(.meters) || sections.contains(.equalizer) || sections.contains(.perChannel),
                sections.contains(.spectrum) || (sections.contains(.equalizer) && equalizer != .simpleTone))
    }

    var equalizer: EqualizerPresentation {
        get { presentation[ProfileSection.equalizer.rawValue]?.equalizer ?? .both }
        set { presentation[ProfileSection.equalizer.rawValue] = SectionPresentationPreference(equalizer: newValue) }
    }
    var normalizedOrder: [ProfileSection] {
        var seen: Set<ProfileSection> = [.deviceSetup]
        return [.deviceSetup] + (order + ProfileSection.allCases).filter { seen.insert($0).inserted }
    }
    func visibleSections(for type: ProfileEndpointKind) -> [ProfileSection] {
        normalizedOrder.filter { $0.applies(to: type) && ($0 == .deviceSetup || !hidden.contains($0)) }
    }
    mutating func move(_ section: ProfileSection, before destination: ProfileSection?) {
        guard section != .deviceSetup, destination != .deviceSetup, section != destination else { return }
        var ordered = normalizedOrder.filter { $0 != section }
        ordered.insert(section, at: destination.flatMap { ordered.firstIndex(of: $0) } ?? ordered.count)
        order = ordered
    }
}

struct ProfileSettingsDraft {
    let original: DeviceProfile
    let originalActivation: ProfileActivationMode
    var name: String
    var outputDevice: PhysicalOutputIdentity
    var selectedType: ProfileEndpointKind
    var sampleRate: Int
    var activation: ProfileActivationMode
    var sectionLayout: ProfileSectionLayout?
    var speakerTopology: SpeakerTopology?
    var spatialSettings: SpatialRenderSettings
    var requestedMode: PlaybackMode?
    var processing: ProcessingProfile?
    var replacesUserEqualizer = false

    init(profile: DeviceProfile, activation: ProfileActivationMode) {
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
    }
    func candidate() throws -> DeviceProfile {
        var typeDraft = ProfileDeviceTypeDraft(profile: original)
        typeDraft.selectedType = selectedType
        var result = try typeDraft.prepare { _ in }
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty else { throw ProfileSettingsError.invalidName }
        result.outputDevice = outputDevice
        result.sampleRate = sampleRate
        result.sectionLayout = sectionLayout
        result.speakerTopology = speakerTopology
        // A type change owns enabled/output mode; geometry and seats remain shared.
        if spatialSettings != original.spatialSettings {
            result.spatialSettings = spatialSettings
            result.synchronizeListeningPositionCorrection()
        }
        if let requestedMode { result.setPlaybackMode(requestedMode) }
        if let processing {
            result.replaceProcessing(processing)
        }
        return result
    }
}

enum ProfileSettingsError: LocalizedError {
    case invalidName, staleDraft, busy, cancelled, runtime(String), rollback(String, String)
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a profile name."
        case .staleDraft: return "This profile changed while Settings was open. Close Settings and reopen it to load the latest values."
        case .busy: return "Wait for the current audio operation to finish, then save again."
        case .cancelled: return "The audio operation was cancelled. Your settings were not saved."
        case .runtime(let detail): return detail
        case .rollback(let failure, let rollback): return "\(failure) The previous settings are still saved, but audio could not be restored: \(rollback)"
        }
    }
}

/// Shared by the runtime adapter and failure-injection tests. Persistence is the
/// final fallible commit, and failed application/commit rolls back the runtime.
@MainActor
enum ProfileSettingsTransaction {
    static func run(preflight: () async throws -> Void,
                    apply: () async throws -> Void,
                    commit: () throws -> Void,
                    rollback: () async throws -> Void) async throws {
        try await preflight()
        do {
            try await apply()
            try commit()
        } catch {
            let failure = error
            do { try await rollback() }
            catch { throw ProfileSettingsError.rollback(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
    }
}

struct AudioInterfaceConfiguration: Codable, Hashable, Sendable {
    var deviceUID: String
    var hardwareChannelCount: Int
    /// Ordered physical destinations for the logical left and right channels.
    var outputChannels: [Int]
    var connectedEndpoint: ProfileEndpointKind

    func validate(deviceUID: String) throws {
        guard self.deviceUID == deviceUID, (2...32).contains(hardwareChannelCount),
              outputChannels.count == 2, Set(outputChannels).count == 2,
              outputChannels.allSatisfy({ (0..<hardwareChannelCount).contains($0) }),
              connectedEndpoint != .audioInterface else {
            throw ProfileSettingsError.runtime("Choose two distinct hardware outputs and identify what is connected to them.")
        }
    }
}
