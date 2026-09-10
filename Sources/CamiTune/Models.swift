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

struct DeviceProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var outputDevice: PhysicalOutputIdentity
    var isEnabled: Bool = true
    var autoActivateWhenProfileDeviceSelected: Bool = false
    var lockOutputVolume: Bool = false
    var outputVolumeScalar: Double = 0.0625
    var sampleRate: Int = 48_000
    var chunkSize: Int = 1024
    var spatialRenderingMode: SpatialRenderingMode = .standard
    var spatialContentMode: SpatialContentMode = .automatic
    var spatialListenerProfile: SpatialListenerProfile?
    var spatialAcousticProfile: SpatialAcousticProfile?

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
        case id, name, outputDevice, outputDeviceUID, outputDeviceName, isEnabled
        case autoActivateWhenProfileDeviceSelected
        case lockOutputVolume, outputVolumeScalar, sampleRate, chunkSize
        case spatialRenderingMode, spatialContentMode, spatialListenerProfile, spatialAcousticProfile, equalizerAPOText, processing
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
        // A damaged or newer optional calibration must not make an otherwise
        // usable output/EQ profile unreadable.
        spatialListenerProfile = try? values.decodeIfPresent(
            SpatialListenerProfile.self, forKey: .spatialListenerProfile
        )
        spatialAcousticProfile = try? values.decodeIfPresent(SpatialAcousticProfile.self, forKey: .spatialAcousticProfile)
        spatialContentMode = (try? values.decodeIfPresent(SpatialContentMode.self, forKey: .spatialContentMode)) ?? .automatic
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
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(outputDevice, forKey: .outputDevice)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(autoActivateWhenProfileDeviceSelected, forKey: .autoActivateWhenProfileDeviceSelected)
        try values.encode(lockOutputVolume, forKey: .lockOutputVolume)
        try values.encode(outputVolumeScalar, forKey: .outputVolumeScalar)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(chunkSize, forKey: .chunkSize)
        try values.encode(spatialRenderingMode, forKey: .spatialRenderingMode)
        try values.encodeIfPresent(spatialListenerProfile, forKey: .spatialListenerProfile)
        try values.encodeIfPresent(spatialAcousticProfile, forKey: .spatialAcousticProfile)
        try values.encode(spatialContentMode, forKey: .spatialContentMode)
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
