import Foundation

package struct PerAppAudioSettings: Codable, Hashable, Sendable {
    package init(volume: Double = 1, isMuted: Bool = false, eqBypassed: Bool = true, equalizerBands: [EQBand] = [], playbackModeOverride: PlaybackMode? = nil, simpleTone: SimpleToneSettings = SimpleToneSettings()) {
        self.volume = volume
        self.isMuted = isMuted
        self.eqBypassed = eqBypassed
        self.equalizerBands = equalizerBands
        self.playbackModeOverride = playbackModeOverride
        self.simpleTone = simpleTone
    }

    package var volume: Double = 1
    package var isMuted = false
    package var eqBypassed = true
    package var equalizerBands: [EQBand] = []
    package var playbackModeOverride: PlaybackMode?
    package var simpleTone = SimpleToneSettings()
    /// Flat gain bands and disabled filters do not light the per-app EQ indicator.
    package var isEqualizerActive: Bool {
        !eqBypassed && (!simpleTone.isNeutral
            || (ParsedEQ(bands: equalizerBands)).hasMeaningfulProcessing)
    }
    package var hasEqualizerProcessing: Bool { !equalizerBands.isEmpty || !simpleTone.isNeutral }
    package func processingBands(sampleRate: Double) -> [EQBand] {
        equalizerBands + (simpleTone.isNeutral ? [] : ((try? SimpleToneFilterFactory.filters(for: simpleTone, sampleRate: sampleRate)) ?? []))
    }
    package enum CodingKeys: String, CodingKey { case volume, isMuted, eqBypassed, equalizerBands, playbackModeOverride, simpleTone }
}

extension PerAppAudioSettings {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        eqBypassed = try c.decodeIfPresent(Bool.self, forKey: .eqBypassed) ?? true
        equalizerBands = try c.decodeIfPresent([EQBand].self, forKey: .equalizerBands) ?? []
        playbackModeOverride = try c.decodeIfPresent(PlaybackMode.self, forKey: .playbackModeOverride)
        simpleTone = try c.decodeIfPresent(SimpleToneSettings.self, forKey: .simpleTone) ?? SimpleToneSettings()
        try simpleTone.validate()
    }
}

package struct PerAppAudioDocument: Codable, Equatable, Sendable {
    package init(schemaVersion: Int = currentVersion, settings: [String: PerAppAudioSettings],
                 profileSettings: [UUID: [String: PerAppAudioSettings]] = [:], localProfileIDs: Set<UUID> = []) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.profileSettings = profileSettings
        self.localProfileIDs = localProfileIDs
    }

    package static let currentVersion = 2
    package var schemaVersion: Int
    package var settings: [String: PerAppAudioSettings]
    package var profileSettings: [UUID: [String: PerAppAudioSettings]]
    package var localProfileIDs: Set<UUID>

    private enum CodingKeys: String, CodingKey { case schemaVersion, settings, profileSettings, localProfileIDs }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported per-app settings version."))
        }
        schemaVersion = Self.currentVersion
        settings = try values.decode([String: PerAppAudioSettings].self, forKey: .settings)
        profileSettings = try values.decodeIfPresent([UUID: [String: PerAppAudioSettings]].self, forKey: .profileSettings) ?? [:]
        localProfileIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .localProfileIDs) ?? []
    }

    package static func decodeDocument(_ data: Data) throws -> Self {
        struct Header: Decodable { var schemaVersion: Int? }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        if header.schemaVersion != nil { return try decoder.decode(Self.self, from: data) }
        return Self(settings: try decoder.decode([String: PerAppAudioSettings].self, from: data))
    }

    package static func decode(_ data: Data) throws -> [String: PerAppAudioSettings] {
        try decodeDocument(data).settings
    }
}

extension PerAppAudioSettings {
    package func automaticHeadroomDB(sampleRate: Double) -> Double {
        guard !eqBypassed, hasEqualizerProcessing else { return 0 }
        let response = EQResponseCalculator().calculate(
            parsed: ParsedEQ(bands: processingBands(sampleRate: sampleRate)),
            sampleRate: sampleRate,
            count: 600
        )
        let boost = max(0, response.map(\.gainDB).max() ?? 0)
        return boost > 0 ? -boost : 0
    }
}
