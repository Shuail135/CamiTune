import Foundation

/// The persisted, engine-independent description of a profile's audio processing.
///
/// This is intentionally separate from `DeviceProfile`: routing and hardware choices
/// belong to the device profile, while this value can later be reused by output,
/// input, and offline processing runtimes.
package struct ProcessingProfile: Codable, Hashable, Sendable {
    package static let spatialRoomCorrectionStageID = UUID(uuidString: "CA117B70-0000-4000-8000-000000000051")!
    package static let currentSchemaVersion = 10
    package static let userPreampStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 3
    ))
    package static let limiterStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 2
    ))
    package static let convolutionStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 4
    ))
    package static let crossfeedStageID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 5
    ))

    package static func limiterStageID(forChannel index: Int) -> UUID {
        let value = UInt32(clamping: index)
        return UUID(uuid: (
            0x43, 0x41, 0x4d, 0x49, 0x54, 0x55, 0x4e, 0x45,
            0x43, 0x48, 0x00, 0x00,
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ))
    }

    package static func delayStageID(forChannel index: Int) -> UUID {
        let value = UInt32(clamping: index)
        return UUID(uuid: (
            0x43, 0x41, 0x4d, 0x49, 0x54, 0x55, 0x4e, 0x45,
            0x44, 0x4c, 0x00, 0x00,
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ))
    }

    package static func convolutionStageID(forChannel index: Int) -> UUID {
        let value = UInt32(clamping: index)
        return UUID(uuid: (
            0x43, 0x41, 0x4d, 0x49, 0x54, 0x55, 0x4e, 0x45,
            0x46, 0x49, 0x52, 0x00,
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ))
    }

    package static func toneStageID(forChannel index: Int) -> UUID {
        let value = UInt32(clamping: index)
        return UUID(uuid: (
            0x43, 0x41, 0x4d, 0x49, 0x54, 0x55, 0x4e, 0x45,
            0x54, 0x4e, 0x00, 0x00,
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ))
    }

    package var schemaVersion: Int
    package var simpleTone = SimpleToneSettings()
    package var global: ProcessingChain
    package var channels: [ChannelProcessing]
    package var groups: [GroupProcessing]
    /// Generation provenance for Auto EQ bands loaded into the user Equalizer.
    package var globalEqualizerProvenance: DeviceCorrectionProfile?

    package init(
        schemaVersion: Int = ProcessingProfile.currentSchemaVersion,
        global: ProcessingChain = ProcessingChain(),
        channels: [ChannelProcessing] = ProcessingProfile.stereoChannels,
        groups: [GroupProcessing] = [],
        globalEqualizerProvenance: DeviceCorrectionProfile? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.global = global
        self.channels = channels
        self.groups = groups
        self.globalEqualizerProvenance = globalEqualizerProvenance
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case simpleTone
        case global
        case channels
        case groups
        case globalEqualizerProvenance
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard storedVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported processing schema version \(storedVersion)."
            )
        }
        simpleTone = try values.decodeIfPresent(SimpleToneSettings.self, forKey: .simpleTone) ?? SimpleToneSettings()
        try simpleTone.validate()
        schemaVersion = Self.currentSchemaVersion
        global = try values.decodeIfPresent(ProcessingChain.self, forKey: .global)
            ?? ProcessingChain()
        global.stages.migrateUserPreampStageID(to: Self.userPreampStageID)
        channels = try values.decodeIfPresent([ChannelProcessing].self, forKey: .channels)
            ?? Self.stereoChannels
        groups = try values.decodeIfPresent([GroupProcessing].self, forKey: .groups) ?? []
        guard Set(groups.map(\.id)).count == groups.count,
              groups.allSatisfy({ !$0.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: .groups, in: values,
                debugDescription: "Group processing identities must be unique and nonempty.")
        }
        globalEqualizerProvenance = try values.decodeIfPresent(
            DeviceCorrectionProfile.self,
            forKey: .globalEqualizerProvenance
        )
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(simpleTone, forKey: .simpleTone)
        try values.encode(global, forKey: .global)
        try values.encode(channels, forKey: .channels)
        try values.encode(groups, forKey: .groups)
        try values.encodeIfPresent(
            globalEqualizerProvenance,
            forKey: .globalEqualizerProvenance
        )
    }

    package static var defaultStereo: ProcessingProfile {
        ProcessingProfile().updatingGlobalEqualizer(
            preampDB: 0,
            bands: EQDefaults.bands
        )
    }

    package static func imported(from parsed: ParsedEQ) -> ProcessingProfile {
        ProcessingProfile().updatingGlobalEqualizer(
            preampDB: parsed.preampDB,
            bands: parsed.bands
        )
    }

    package var globalEqualizer: ParsedEQ {
        let gain = global.stages.userPreampStage(stageID: Self.userPreampStageID)
        let equalizer = global.stages.firstEqualizerStage
        return ParsedEQ(
            preampDB: gain?.isEnabled == true ? gain?.gainDB ?? 0 : 0,
            bands: equalizer?.isEnabled == true ? equalizer?.bands ?? [] : [],
            warnings: []
        )
    }

    package var deviceCorrection: DeviceCorrectionProfile? {
        for stage in global.stages {
            if case .deviceCorrection(var correction) = stage.processor {
                correction.isEnabled = stage.isEnabled
                return correction
            }
        }
        return nil
    }

    package var limiter: (isEnabled: Bool, processor: LimiterProcessor)? {
        global.stages.firstLimiterStage
    }

    package var convolution: (isEnabled: Bool, processor: ConvolutionProcessor)? {
        global.stages.firstConvolutionStage
    }

    package var crossfeed: (isEnabled: Bool, processor: CrossfeedProcessor)? {
        global.stages.firstCrossfeedStage
    }

    package var limiterEnabled: Bool {
        limiter?.isEnabled ?? false
    }

    /// Combined response for explicit legacy export and compatibility checks.
    /// Opening User Equalizer must use globalEqualizer so correction remains
    /// separate until the user explicitly transfers it.
    package var globalEqualizerIncludingDeviceCorrection: ParsedEQ {
        var result = globalEqualizer
        guard let correction = deviceCorrection, correction.isEnabled else { return result }
        result.bands.insert(contentsOf: correction.filters, at: 0)
        return result
    }

    package mutating func setGlobalEqualizer(preampDB: Double, bands: [EQBand]) {
        global.stages.upsertGain(
            gainDB: preampDB,
            stageID: Self.userPreampStageID
        )
        global.stages.upsertEqualizer(bands: bands)
    }

    package mutating func setDeviceCorrection(_ correction: DeviceCorrectionProfile?) {
        let existingIndex = global.stages.firstIndex {
            if case .deviceCorrection = $0.processor { return true }
            return false
        }
        guard var correction else {
            if let existingIndex { global.stages.remove(at: existingIndex) }
            return
        }
        let enabled = correction.isEnabled
        correction.isEnabled = true
        if let existingIndex {
            global.stages[existingIndex].isEnabled = enabled
            global.stages[existingIndex].processor = .deviceCorrection(correction)
        } else {
            global.stages.insert(
                ProcessingStage(
                    isEnabled: enabled,
                    processor: .deviceCorrection(correction)
                ),
                at: 0
            )
        }
    }

    package mutating func setLimiterEnabled(_ enabled: Bool) {
        global.stages.upsertLimiter(enabled: enabled, stageID: Self.limiterStageID)
    }

    package mutating func setConvolution(
        _ convolution: ConvolutionProcessor?,
        enabled: Bool = true
    ) {
        global.stages.upsertConvolution(
            convolution,
            enabled: enabled,
            stageID: Self.convolutionStageID
        )
    }

    package mutating func setCrossfeed(
        _ crossfeed: CrossfeedProcessor?,
        enabled: Bool = true
    ) {
        global.stages.upsertCrossfeed(
            crossfeed,
            enabled: enabled,
            stageID: Self.crossfeedStageID
        )
    }

    package func convolution(forChannel index: Int) -> (isEnabled: Bool, processor: ConvolutionProcessor)? {
        channels.first { $0.index == index }?.chain.stages.firstConvolutionStage
    }

    package mutating func setConvolution(_ convolution: ConvolutionProcessor?, enabled: Bool = true, forChannel index: Int) {
        guard let position = channels.firstIndex(where: { $0.index == index }) else { return }
        channels[position].chain.stages.upsertConvolution(convolution, enabled: enabled,
            stageID: Self.convolutionStageID(forChannel: index))
    }

    package func convolution(forGroup id: SpeakerGroupID) -> (isEnabled: Bool, processor: ConvolutionProcessor)? {
        groups.first { $0.id == id }?.chain.stages.firstConvolutionStage
    }

    package mutating func setConvolution(_ convolution: ConvolutionProcessor?, enabled: Bool = true, forGroup id: SpeakerGroupID) {
        guard convolution != nil || groups.contains(where: { $0.id == id }) else { return }
        if !groups.contains(where: { $0.id == id }) { groups.append(GroupProcessing(id: id)) }
        guard let position = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[position].chain.stages.upsertConvolution(convolution, enabled: enabled, stageID: id.stageID("convolution"))
    }

    package func settings(forChannel index: Int) -> ChannelProcessingSettings? {
        guard let channel = channels.first(where: { $0.index == index }) else { return nil }
        return ChannelProcessingSettings(
            gainDB: channel.chain.stages.firstGainStage.flatMap {
                $0.isEnabled ? $0.gainDB : nil
            } ?? 0,
            bands: channel.chain.stages.firstEqualizerStage.flatMap {
                $0.isEnabled ? $0.bands : nil
            } ?? [],
            delayMilliseconds: channel.chain.stages.firstDelayStage.flatMap {
                $0.isEnabled ? $0.processor.milliseconds : nil
            } ?? 0,
            limiterEnabled: channel.chain.stages.firstLimiterStage?.isEnabled ?? false,
            simpleTone: channel.chain.simpleTone ?? SimpleToneSettings()
        )
    }

    package mutating func setChannelProcessing(
        index: Int,
        role: ChannelRole,
        gainDB: Double,
        bands: [EQBand],
        delayMilliseconds: Double? = nil,
        limiterEnabled: Bool? = nil,
        simpleTone: SimpleToneSettings? = nil
    ) {
        if let channelIndex = channels.firstIndex(where: { $0.index == index }) {
            if let simpleTone { channels[channelIndex].chain.simpleTone = simpleTone }
            channels[channelIndex].role = role
            channels[channelIndex].chain.stages.upsertGain(gainDB: gainDB)
            channels[channelIndex].chain.stages.upsertEqualizer(bands: bands)
            if let delayMilliseconds {
                channels[channelIndex].chain.stages.upsertDelay(
                    milliseconds: delayMilliseconds,
                    stageID: Self.delayStageID(forChannel: index)
                )
            }
            if let limiterEnabled {
                channels[channelIndex].chain.stages.upsertLimiter(
                    enabled: limiterEnabled,
                    stageID: Self.limiterStageID(forChannel: index)
                )
            }
        } else {
            var chain = ProcessingChain(simpleTone: simpleTone)
            chain.stages.upsertGain(gainDB: gainDB)
            chain.stages.upsertEqualizer(bands: bands)
            if let delayMilliseconds {
                chain.stages.upsertDelay(
                    milliseconds: delayMilliseconds,
                    stageID: Self.delayStageID(forChannel: index)
                )
            }
            if let limiterEnabled {
                chain.stages.upsertLimiter(
                    enabled: limiterEnabled,
                    stageID: Self.limiterStageID(forChannel: index)
                )
            }
            channels.append(ChannelProcessing(index: index, role: role, chain: chain))
            channels.sort { $0.index < $1.index }
        }
    }

    package func updatingGlobalEqualizer(preampDB: Double, bands: [EQBand]) -> ProcessingProfile {
        var copy = self
        copy.setGlobalEqualizer(preampDB: preampDB, bands: bands)
        return copy
    }

    private static let stereoChannels = [
        ChannelProcessing(index: 0, role: .left),
        ChannelProcessing(index: 1, role: .right)
    ]
}

package struct ProcessingChain: Codable, Hashable, Sendable {
    package var stages: [ProcessingStage]

    /// Channel tone travels with the physical output's chain. Missing legacy values are neutral.
    package var simpleTone: SimpleToneSettings?

    package init(stages: [ProcessingStage] = [], simpleTone: SimpleToneSettings? = nil) {
        self.stages = stages
        self.simpleTone = simpleTone
    }
}

package struct ChannelProcessing: Identifiable, Codable, Hashable, Sendable {
    package var index: Int
    package var role: ChannelRole
    package var chain: ProcessingChain

    package var id: Int { index }

    package init(index: Int, role: ChannelRole, chain: ProcessingChain = ProcessingChain()) {
        self.index = index
        self.role = role
        self.chain = chain
    }
}

package struct ChannelProcessingSettings: Hashable, Sendable {
    package init(
        gainDB: Double,
        bands: [EQBand],
        delayMilliseconds: Double,
        limiterEnabled: Bool,
        simpleTone: SimpleToneSettings = SimpleToneSettings()
    ) {
        self.gainDB = gainDB
        self.bands = bands
        self.delayMilliseconds = delayMilliseconds
        self.limiterEnabled = limiterEnabled
        self.simpleTone = simpleTone
    }

    package var gainDB: Double
    package var bands: [EQBand]
    package var delayMilliseconds: Double
    package var limiterEnabled: Bool
    package var simpleTone = SimpleToneSettings()

    package static let identity = ChannelProcessingSettings(
        gainDB: 0,
        bands: [],
        delayMilliseconds: 0,
        limiterEnabled: false
    )

    package var isIdentity: Bool {
        gainDB == 0 && !bands.contains(where: \.enabled)
            && delayMilliseconds == 0 && !limiterEnabled && simpleTone.isNeutral
    }
}

/// Semantic channel identity is stored separately from the physical channel index.
/// That lets layouts and mixers be changed later without redefining processing data.

package struct ProcessingStage: Identifiable, Codable, Hashable, Sendable {
    package var id: UUID
    package var isEnabled: Bool
    package var processor: Processor

    package init(id: UUID = UUID(), isEnabled: Bool = true, processor: Processor) {
        self.id = id
        self.isEnabled = isEnabled
        self.processor = processor
    }

    package enum Processor: Codable, Hashable, Sendable {
        case gain(GainProcessor)
        case equalizer(EqualizerProcessor)
        case deviceCorrection(DeviceCorrectionProfile)
        case convolution(ConvolutionProcessor)
        case crossfeed(CrossfeedProcessor)
        case delay(DelayProcessor)
        case limiter(LimiterProcessor)

        private enum CodingKeys: String, CodingKey {
            case type
            case gain
            case equalizer
            case deviceCorrection
            case convolution
            case crossfeed
            case delay
            case limiter
        }

        private enum Kind: String, Codable {
            case gain
            case equalizer
            case deviceCorrection
            case convolution
            case crossfeed
            case delay
            case limiter
        }

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .type) {
            case .gain:
                self = .gain(try values.decode(GainProcessor.self, forKey: .gain))
            case .equalizer:
                self = .equalizer(try values.decode(EqualizerProcessor.self, forKey: .equalizer))
            case .deviceCorrection:
                self = .deviceCorrection(
                    try values.decode(DeviceCorrectionProfile.self, forKey: .deviceCorrection)
                )
            case .convolution:
                self = .convolution(
                    try values.decode(ConvolutionProcessor.self, forKey: .convolution)
                )
            case .crossfeed:
                self = .crossfeed(
                    try values.decode(CrossfeedProcessor.self, forKey: .crossfeed)
                )
            case .delay:
                self = .delay(try values.decode(DelayProcessor.self, forKey: .delay))
            case .limiter:
                self = .limiter(try values.decode(LimiterProcessor.self, forKey: .limiter))
            }
        }

        package func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .gain(let processor):
                try values.encode(Kind.gain, forKey: .type)
                try values.encode(processor, forKey: .gain)
            case .equalizer(let processor):
                try values.encode(Kind.equalizer, forKey: .type)
                try values.encode(processor, forKey: .equalizer)
            case .deviceCorrection(let correction):
                try values.encode(Kind.deviceCorrection, forKey: .type)
                try values.encode(correction, forKey: .deviceCorrection)
            case .convolution(let processor):
                try values.encode(Kind.convolution, forKey: .type)
                try values.encode(processor, forKey: .convolution)
            case .crossfeed(let processor):
                try values.encode(Kind.crossfeed, forKey: .type)
                try values.encode(processor, forKey: .crossfeed)
            case .delay(let processor):
                try values.encode(Kind.delay, forKey: .type)
                try values.encode(processor, forKey: .delay)
            case .limiter(let processor):
                try values.encode(Kind.limiter, forKey: .type)
                try values.encode(processor, forKey: .limiter)
            }
        }
    }
}

package struct GainProcessor: Codable, Hashable, Sendable {
    package init(gainDB: Double) {
        self.gainDB = gainDB
    }

    package var gainDB: Double
}

package struct EqualizerProcessor: Codable, Hashable, Sendable {
    package init(bands: [EQBand]) {
        self.bands = bands
    }

    package var bands: [EQBand]
}

package struct ConvolutionProcessor: Codable, Hashable, Sendable {
    package var asset: ImpulseResponseAsset
    /// Zero-based channel selected from a mono or multichannel WAV.
    package var impulseChannel: Int
    /// Use individual source mappings within the global FIR.
    package var usesCorrespondingChannels: Bool
    /// Nil preserves legacy automatic correspondence; an empty array bypasses every output.
    package var channelAssignments: [ImpulseResponseAssignment]?

    package init(asset: ImpulseResponseAsset, impulseChannel: Int = 0, usesCorrespondingChannels: Bool = false,
                 channelAssignments: [ImpulseResponseAssignment]? = nil) {
        self.asset = asset
        self.impulseChannel = impulseChannel
        self.usesCorrespondingChannels = usesCorrespondingChannels
        self.channelAssignments = channelAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case asset, impulseChannel, usesCorrespondingChannels, channelAssignments
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        asset = try values.decode(ImpulseResponseAsset.self, forKey: .asset)
        impulseChannel = try values.decode(Int.self, forKey: .impulseChannel)
        usesCorrespondingChannels = try values.decodeIfPresent(Bool.self, forKey: .usesCorrespondingChannels) ?? false
        channelAssignments = try values.decodeIfPresent([ImpulseResponseAssignment].self, forKey: .channelAssignments)
    }
}

package struct CrossfeedProcessor: Codable, Hashable, Sendable {
    package init(amountPercent: Double, delayMilliseconds: Double, cutoffFrequency: Double) {
        self.amountPercent = amountPercent
        self.delayMilliseconds = delayMilliseconds
        self.cutoffFrequency = cutoffFrequency
    }

    package static let standard = CrossfeedProcessor(
        amountPercent: 25,
        delayMilliseconds: 0.3,
        cutoffFrequency: 700
    )

    /// Opposite-channel low-frequency contribution, from 0% (none) to 100%
    /// (equal-amplitude low-frequency contribution).
    package var amountPercent: Double
    package var delayMilliseconds: Double
    package var cutoffFrequency: Double

    package var crossfeedCoefficient: Double { amountPercent / 100 }

    package var crossfeedGainDB: Double {
        let coefficient = crossfeedCoefficient
        guard coefficient > 0 else { return -120 }
        return 20 * log10(coefficient)
    }

    package var maximumBoostDB: Double {
        20 * log10(1 + max(0, crossfeedCoefficient))
    }
}

package struct DelayProcessor: Codable, Hashable, Sendable {
    package init(milliseconds: Double) {
        self.milliseconds = milliseconds
    }

    package var milliseconds: Double
}

package struct LimiterProcessor: Codable, Hashable, Sendable {
    package init(clipLimitDB: Double, softClip: Bool) {
        self.clipLimitDB = clipLimitDB
        self.softClip = softClip
    }

    package static let standard = LimiterProcessor(clipLimitDB: -0.5, softClip: false)

    package var clipLimitDB: Double
    package var softClip: Bool
}

private extension Array where Element == ProcessingStage {
    var firstGainStage: (isEnabled: Bool, gainDB: Double)? {
        for stage in self {
            if case .gain(let gain) = stage.processor {
                return (stage.isEnabled, gain.gainDB)
            }
        }
        return nil
    }

    var firstEqualizerStage: (isEnabled: Bool, bands: [EQBand])? {
        for stage in self where stage.id != ProcessingProfile.spatialRoomCorrectionStageID {
            if case .equalizer(let equalizer) = stage.processor {
                return (stage.isEnabled, equalizer.bands)
            }
        }
        return nil
    }

    var firstLimiterStage: (isEnabled: Bool, processor: LimiterProcessor)? {
        for stage in self {
            if case .limiter(let limiter) = stage.processor {
                return (stage.isEnabled, limiter)
            }
        }
        return nil
    }

    var firstConvolutionStage: (isEnabled: Bool, processor: ConvolutionProcessor)? {
        for stage in self {
            if case .convolution(let convolution) = stage.processor {
                return (stage.isEnabled, convolution)
            }
        }
        return nil
    }

    var firstCrossfeedStage: (isEnabled: Bool, processor: CrossfeedProcessor)? {
        for stage in self {
            if case .crossfeed(let crossfeed) = stage.processor {
                return (stage.isEnabled, crossfeed)
            }
        }
        return nil
    }

    var firstDelayStage: (isEnabled: Bool, processor: DelayProcessor)? {
        for stage in self {
            if case .delay(let delay) = stage.processor {
                return (stage.isEnabled, delay)
            }
        }
        return nil
    }

    func userPreampStage(stageID: UUID) -> (isEnabled: Bool, gainDB: Double)? {
        if let stage = first(where: { $0.id == stageID }),
           case .gain(let gain) = stage.processor {
            return (stage.isEnabled, gain.gainDB)
        }
        return firstGainStage
    }

    mutating func migrateUserPreampStageID(to stageID: UUID) {
        if let reservedIndex = firstIndex(where: { $0.id == stageID }) {
            if case .gain = self[reservedIndex].processor { return }
            // A malformed/hand-authored profile may already use the reserved
            // ID for another stage. Preserve that stage under a fresh identity
            // before assigning the semantic User-preamp identity.
            self[reservedIndex].id = UUID()
        }
        guard let legacyGainIndex = firstIndex(where: {
            if case .gain = $0.processor { return true }
            return false
        }) else { return }
        self[legacyGainIndex].id = stageID
    }

    mutating func upsertGain(gainDB: Double, stageID: UUID? = nil) {
        let index: Int?
        if let stageID {
            index = firstIndex(where: { stage in
                guard stage.id == stageID else { return false }
                if case .gain = stage.processor { return true }
                return false
            })
        } else {
            index = firstIndex(where: {
                if case .gain = $0.processor { return true }
                return false
            })
        }
        if let index {
            self[index].processor = .gain(GainProcessor(gainDB: gainDB))
            self[index].isEnabled = true
        } else {
            insert(ProcessingStage(
                id: stageID ?? UUID(),
                processor: .gain(GainProcessor(gainDB: gainDB))
            ), at: 0)
        }
    }

    mutating func upsertEqualizer(bands: [EQBand], stageID: UUID? = nil) {
        if let index = firstIndex(where: {
            guard $0.id != ProcessingProfile.spatialRoomCorrectionStageID else { return false }
            if case .equalizer = $0.processor { return true }
            return false
        }) {
            self[index].processor = .equalizer(EqualizerProcessor(bands: bands))
            self[index].isEnabled = true
        } else {
            let insertion = firstIndex {
                switch $0.processor { case .convolution, .delay, .crossfeed, .limiter: return true; default: return false }
            } ?? endIndex
            insert(ProcessingStage(id: stageID ?? UUID(), processor: .equalizer(EqualizerProcessor(bands: bands))), at: insertion)
        }
    }

    mutating func upsertLimiter(enabled: Bool, stageID: UUID) {
        if let index = firstIndex(where: {
            if case .limiter = $0.processor { return true }
            return false
        }) {
            self[index].isEnabled = enabled
        } else {
            append(ProcessingStage(
                id: stageID,
                isEnabled: enabled,
                processor: .limiter(.standard)
            ))
        }
    }

    mutating func upsertDelay(milliseconds: Double, stageID: UUID) {
        if let index = firstIndex(where: {
            if case .delay = $0.processor { return true }
            return false
        }) {
            self[index].processor = .delay(DelayProcessor(milliseconds: milliseconds))
            self[index].isEnabled = true
            return
        }
        let insertionIndex = firstIndex(where: {
            if case .limiter = $0.processor { return true }
            return false
        }) ?? endIndex
        insert(
            ProcessingStage(
                id: stageID,
                processor: .delay(DelayProcessor(milliseconds: milliseconds))
            ),
            at: insertionIndex
        )
    }

    mutating func upsertConvolution(
        _ convolution: ConvolutionProcessor?,
        enabled: Bool,
        stageID: UUID
    ) {
        let index = firstIndex(where: {
            if case .convolution = $0.processor { return true }
            return false
        })
        guard let convolution else {
            if let index { remove(at: index) }
            return
        }
        // Preserve an existing identity while repairing legacy insertion order.
        let identity = index.map { self[$0].id } ?? stageID
        if let index { remove(at: index) }

        // FIR follows ordinary response shaping and remains before the terminal
        // limiter even when an older profile's stages were hand-authored.
        let insertionIndex = firstIndex(where: {
            switch $0.processor {
            case .delay, .crossfeed, .limiter: return true
            default: return false
            }
        }) ?? endIndex
        insert(
            ProcessingStage(
                id: identity,
                isEnabled: enabled,
                processor: .convolution(convolution)
            ),
            at: insertionIndex
        )
    }

    mutating func upsertCrossfeed(
        _ crossfeed: CrossfeedProcessor?,
        enabled: Bool,
        stageID: UUID
    ) {
        let index = firstIndex(where: {
            if case .crossfeed = $0.processor { return true }
            return false
        })
        guard let crossfeed else {
            if let index { remove(at: index) }
            return
        }
        if let index {
            self[index].processor = .crossfeed(crossfeed)
            self[index].isEnabled = enabled
            return
        }
        let insertionIndex = firstIndex(where: {
            if case .limiter = $0.processor { return true }
            return false
        }) ?? endIndex
        insert(
            ProcessingStage(
                id: stageID,
                isEnabled: enabled,
                processor: .crossfeed(crossfeed)
            ),
            at: insertionIndex
        )
    }
}

extension ProcessingChain {
    package var channelSettings: ChannelProcessingSettings {
        ChannelProcessingSettings(
            gainDB: stages.firstGainStage.flatMap { $0.isEnabled ? $0.gainDB : nil } ?? 0,
            bands: stages.firstEqualizerStage.flatMap { $0.isEnabled ? $0.bands : nil } ?? [],
            delayMilliseconds: stages.firstDelayStage.flatMap { $0.isEnabled ? $0.processor.milliseconds : nil } ?? 0,
            limiterEnabled: stages.firstLimiterStage?.isEnabled ?? false,
            simpleTone: simpleTone ?? SimpleToneSettings())
    }
}

extension ProcessingProfile {
    package func settings(forGroup id: SpeakerGroupID) -> ChannelProcessingSettings? {
        groups.first { $0.id == id }?.chain.channelSettings
    }

    package mutating func setGroupProcessing(id: SpeakerGroupID, settings: ChannelProcessingSettings) {
        var group = groups.first { $0.id == id } ?? GroupProcessing(id: id)
        group.chain.simpleTone = settings.simpleTone
        let gainID = group.chain.stages.first { if case .gain = $0.processor { return true }; return false }?.id
        group.chain.stages.upsertGain(gainDB: settings.gainDB, stageID: gainID ?? id.stageID("gain"))
        group.chain.stages.upsertEqualizer(bands: settings.bands, stageID: id.stageID("eq"))
        group.chain.stages.upsertDelay(milliseconds: settings.delayMilliseconds, stageID: id.stageID("delay"))
        group.chain.stages.upsertLimiter(enabled: settings.limiterEnabled, stageID: id.stageID("limiter"))
        if let index = groups.firstIndex(where: { $0.id == id }) { groups[index] = group }
        else { groups.append(group) }
    }
}
